use crate::packet::{PacketBuf, PacketPool};
use arc_swap::ArcSwap;
use socket2::SockRef;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::{Semaphore, mpsc};
use tokio_util::sync::CancellationToken;

const MAX_CONCURRENT_DNS_QUERIES: usize = 256;
const MAX_UDP_SESSIONS: usize = 4096;

/// Bounded capacity of the direct-relay → TUN inbound hand-off. Keeps a slow
/// TUN writer from letting smoltcp/DNS egress grow without limit and starve the
/// shared packet pool.
pub const DIRECT_RELAY_INBOUND_CAPACITY: usize = 128;

fn dns_query_slots() -> &'static Arc<Semaphore> {
    static SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();
    SLOTS.get_or_init(|| Arc::new(Semaphore::new(MAX_CONCURRENT_DNS_QUERIES)))
}

async fn resolve_direct_domain(domain: &str) -> Vec<IpAddr> {
    if let Ok(addrs) = tokio::net::lookup_host((domain, 443)).await {
        let list: Vec<IpAddr> = addrs.map(|sa| sa.ip()).collect();
        if !list.is_empty() {
            return list;
        }
    }
    crate::dns::global()
        .lookup(domain)
        .await
        .unwrap_or_default()
}

async fn run_full_preresolve_task(
    direct_ips: Arc<ArcSwap<std::collections::HashSet<IpAddr>>>,
    dns_domain_map: Arc<crate::sni::DnsDomainMap>,
    domain_routing: Arc<ArcSwap<crate::dispatcher::DomainRoutingConfig>>,
    origin: crate::sni::RoutingLearningOrigin,
    supplied_domains: Vec<String>,
    #[cfg(test)] test_hooks: Arc<LearnedTestHooks>,
) {
    #[cfg(test)]
    let mut _test_completion = None;
    // Сервер уже прислал эффективный список с учётом включённых шаблонов.
    // Клиент не расширяет его собственным RU-пресетом.
    let mut domains_to_resolve = Vec::new();
    for d in supplied_domains {
        let trimmed = d.trim().to_lowercase();
        if !trimmed.is_empty() && !domains_to_resolve.contains(&trimmed) {
            domains_to_resolve.push(trimmed);
        }
    }
    if domains_to_resolve.is_empty() {
        return;
    }

    let sem = Arc::new(tokio::sync::Semaphore::new(12));
    let mut handles = Vec::with_capacity(domains_to_resolve.len());
    for domain in domains_to_resolve {
        let permit = match sem.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => return,
        };
        let d = domain.clone();
        #[cfg(test)]
        let resolved = test_hooks.resolutions.lock().ok().and_then(|values| {
            values
                .as_ref()
                .map(|values| values.get(&d).cloned().unwrap_or_default())
        });
        handles.push(tokio::spawn(async move {
            let _permit = permit;
            #[cfg(test)]
            let ips = match resolved {
                Some(ips) => ips,
                None => resolve_direct_domain(&d).await,
            };
            #[cfg(not(test))]
            let ips = resolve_direct_domain(&d).await;
            (d, ips)
        }));
    }

    let mut resolved = Vec::with_capacity(handles.len());
    for handle in handles {
        if let Ok((domain_name, ips)) = handle.await {
            #[cfg(test)]
            if _test_completion.is_none() {
                _test_completion = test_hooks
                    .pause(LearnedCheckpointStage::PreresolveBeforeCommit, &domain_name)
                    .await;
            }
            resolved.push((domain_name, ips));
        }
    }

    if !origin.config.enabled || !dns_domain_map.origin_is_current(&origin, &domain_routing) {
        return;
    }

    #[cfg(test)]
    if _test_completion.is_none() {
        let domain = origin
            .config
            .direct_domains
            .first()
            .map(String::as_str)
            .unwrap_or_default();
        _test_completion = test_hooks
            .pause(LearnedCheckpointStage::PreresolveAfterCheck, domain)
            .await;
    }

    for (domain, ips) in &resolved {
        let direct = crate::sni::is_direct_domain_mode(
            domain,
            origin.config.is_whitelist,
            &origin.config.direct_domains,
        );
        // This is the final check+commit, not the optimistic check above. Both
        // the DNS association and direct IPs are published under the epoch lock.
        if !dns_domain_map.publish_routing_learning(
            &domain_routing,
            &direct_ips,
            &origin,
            domain,
            ips,
            direct,
        ) {
            return;
        }
    }
    if !origin.config.is_whitelist {
        crate::log_error!(
            "[ДОМЕНЫ] Разрешено прямых IP (ЧС): {}",
            direct_ips.load().len()
        );
    } else {
        crate::log_error!(
            "[ДОМЕНЫ] Предрезолвлен список БС для туннеля (доменов: {})",
            resolved.len()
        );
    }
}

fn is_local_or_private_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || (octets[0] == 100 && (octets[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_unique_local()
                || v6.is_unicast_link_local()
                || v6.is_multicast()
                || v6
                    .to_ipv4_mapped()
                    .is_some_and(|v4| is_local_or_private_ip(&IpAddr::V4(v4)))
        }
    }
}

const MAX_UDP_VERDICTS: usize = 4096;
const UDP_VERDICT_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct VerdictKey {
    src: SocketAddr,
    dst: SocketAddr,
    protocol: u8,
}

#[derive(Default)]
struct VerdictCache {
    entries: HashMap<VerdictKey, (crate::sni::RouteVerdict, Instant)>,
    /// Меняется при любой routing-инвалидации, включая UPDATE_IPS без DNS.
    generation: u64,
    routing_config: Option<Arc<crate::dispatcher::DomainRoutingConfig>>,
}

struct UdpRouteSnapshot {
    origin: crate::sni::RoutingLearningOrigin,
    generation: u64,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum UdpRouteCheckpointStage {
    Snapshot,
    Verdict,
    Send,
}

#[cfg(test)]
struct UdpRouteCheckpoint {
    stage: UdpRouteCheckpointStage,
    reached: Arc<tokio::sync::Notify>,
    resume: Arc<tokio::sync::Notify>,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LearnedCheckpointStage {
    PreresolveBeforeCommit,
    PreresolveAfterCheck,
    DnsReplyBeforeCommit,
    UdpReplyBeforeCommit,
}

#[cfg(test)]
struct LearnedCheckpoint {
    stage: LearnedCheckpointStage,
    domain: String,
    reached: Arc<tokio::sync::Notify>,
    resume: Arc<tokio::sync::Notify>,
    done: Arc<tokio::sync::Notify>,
}

#[cfg(test)]
struct LearnedTestCompletion(Arc<tokio::sync::Notify>);

#[cfg(test)]
impl Drop for LearnedTestCompletion {
    fn drop(&mut self) {
        self.0.notify_one();
    }
}

#[cfg(test)]
#[derive(Default)]
pub(crate) struct LearnedTestHooks {
    checkpoint: std::sync::Mutex<Option<LearnedCheckpoint>>,
    upstreams: std::sync::Mutex<Option<Vec<SocketAddr>>>,
    resolutions: std::sync::Mutex<Option<HashMap<String, Vec<IpAddr>>>>,
    observation:
        std::sync::Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
}

#[cfg(test)]
impl LearnedTestHooks {
    pub(crate) fn set_resolutions(&self, values: HashMap<String, Vec<IpAddr>>) {
        *self.resolutions.lock().unwrap() = Some(values);
    }

    pub(crate) fn checkpoint(
        &self,
        stage: LearnedCheckpointStage,
        domain: &str,
    ) -> (
        Arc<tokio::sync::Notify>,
        Arc<tokio::sync::Notify>,
        Arc<tokio::sync::Notify>,
    ) {
        let reached = Arc::new(tokio::sync::Notify::new());
        let resume = Arc::new(tokio::sync::Notify::new());
        let done = Arc::new(tokio::sync::Notify::new());
        *self.checkpoint.lock().unwrap() = Some(LearnedCheckpoint {
            stage,
            domain: domain.to_owned(),
            reached: reached.clone(),
            resume: resume.clone(),
            done: done.clone(),
        });
        (reached, resume, done)
    }

    async fn pause(
        &self,
        stage: LearnedCheckpointStage,
        domain: &str,
    ) -> Option<LearnedTestCompletion> {
        let checkpoint = self.checkpoint.lock().ok().and_then(|mut point| {
            if point
                .as_ref()
                .is_some_and(|point| point.stage == stage && point.domain == domain)
            {
                point.take()
            } else {
                None
            }
        });
        let point = checkpoint?;
        let completion = LearnedTestCompletion(point.done);
        point.reached.notify_one();
        point.resume.notified().await;
        Some(completion)
    }

    pub(crate) fn pause_observation(&self) {
        let point = self
            .observation
            .lock()
            .ok()
            .and_then(|mut point| point.take());
        if let Some((reached, resume)) = point {
            let _ = reached.send(());
            let _ = resume.recv();
        }
    }
}

impl VerdictCache {
    fn get(&self, key: &VerdictKey, now: Instant) -> Option<crate::sni::RouteVerdict> {
        self.entries.get(key).and_then(|(verdict, seen)| {
            (now.duration_since(*seen) < UDP_VERDICT_TTL).then_some(*verdict)
        })
    }

    fn insert(&mut self, key: VerdictKey, verdict: crate::sni::RouteVerdict, now: Instant) {
        if self.entries.len() >= MAX_UDP_VERDICTS {
            self.retain_fresh(now);
            if self.entries.len() >= MAX_UDP_VERDICTS {
                self.entries.clear();
            }
        }
        self.entries.insert(key, (verdict, now));
    }

    fn retain_fresh(&mut self, now: Instant) {
        self.entries
            .retain(|_, (_, seen)| now.duration_since(*seen) < UDP_VERDICT_TTL);
    }

    fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.routing_config = None;
        self.entries.clear();
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

pub struct DirectRelay {
    domain_routing: Arc<ArcSwap<crate::dispatcher::DomainRoutingConfig>>,
    direct_ips: Arc<ArcSwap<std::collections::HashSet<IpAddr>>>,
    dns_domain_map: Arc<crate::sni::DnsDomainMap>,
    pool: Arc<PacketPool>,
    inbound_tx: mpsc::Sender<PacketBuf>,
    direct_pkt_tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    active_tcp: Arc<RwLock<HashMap<(SocketAddr, SocketAddr), std::time::Instant>>>,
    udp_verdicts: Arc<RwLock<VerdictCache>>,
    udp_sessions: Arc<RwLock<HashMap<SocketAddr, Arc<tokio::net::UdpSocket>>>>,
    shutdown: CancellationToken,
    #[cfg(test)]
    udp_route_checkpoint: std::sync::Mutex<Option<UdpRouteCheckpoint>>,
    #[cfg(test)]
    pub(crate) udp_test_target: Option<SocketAddr>,
    #[cfg(test)]
    pub(crate) learned_test_hooks: Arc<LearnedTestHooks>,
}

impl Drop for DirectRelay {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

impl DirectRelay {
    #[cfg(test)]
    pub(crate) fn routing_test_udp_verdict(
        &self,
        src: SocketAddr,
        dst: SocketAddr,
    ) -> Option<crate::sni::RouteVerdict> {
        self.udp_verdicts.read().unwrap().get(
            &VerdictKey {
                src,
                dst,
                protocol: 17,
            },
            Instant::now(),
        )
    }

    pub fn new(
        domain_routing: Arc<ArcSwap<crate::dispatcher::DomainRoutingConfig>>,
        direct_ips: Arc<ArcSwap<std::collections::HashSet<IpAddr>>>,
        dns_domain_map: Arc<crate::sni::DnsDomainMap>,
        pool: Arc<PacketPool>,
        inbound_tx: mpsc::Sender<PacketBuf>,
    ) -> std::io::Result<Self> {
        let shutdown = CancellationToken::new();
        #[cfg(test)]
        let learned_test_hooks = Arc::new(LearnedTestHooks::default());
        let origin = dns_domain_map.routing_origin(&domain_routing);
        let config = &origin.config;
        if config.enabled
            && let Ok(handle) = tokio::runtime::Handle::try_current()
        {
            let ips_clone = direct_ips.clone();
            let dns_map_clone = dns_domain_map.clone();
            let routing_clone = domain_routing.clone();
            let custom_domains = config.direct_domains.to_vec();
            #[cfg(test)]
            let test_hooks = learned_test_hooks.clone();
            handle.spawn(async move {
                run_full_preresolve_task(
                    ips_clone,
                    dns_map_clone,
                    routing_clone,
                    origin,
                    custom_domains,
                    #[cfg(test)]
                    test_hooks,
                )
                .await;
            });
        }

        let (stack_res, runner, _udp_sock, tcp_listener) =
            netstack_smoltcp::StackBuilder::default()
                .enable_tcp(true)
                .enable_udp(false)
                .enable_icmp(false)
                .mtu(1500)
                .tcp_recv_buffer_size(65536)
                .tcp_send_buffer_size(65536)
                .stack_buffer_size(4096)
                .tcp_buffer_size(4096)
                .build()?;

        if let Some(runner) = runner {
            let shutdown = shutdown.clone();
            tokio::spawn(async move {
                tokio::select! {
                    result = runner => {
                        if let Err(e) = result {
                            crate::log_error!("[SMOLTCP] Runner error: {e}");
                        }
                    }
                    _ = shutdown.cancelled() => {}
                }
            });
        }

        let (mut stack_sink, mut stack_stream) = futures::StreamExt::split(stack_res);
        let (direct_pkt_tx, mut direct_pkt_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(10000);

        let shutdown_ingress = shutdown.clone();
        tokio::spawn(async move {
            use futures::SinkExt;
            loop {
                tokio::select! {
                    _ = shutdown_ingress.cancelled() => break,
                    pkt = direct_pkt_rx.recv() => {
                        let Some(pkt) = pkt else {
                            break;
                        };
                        if let Err(e) = stack_sink.send(pkt).await {
                            crate::log_error!("[SMOLTCP] Ingress packet delivery error: {e}");
                            break;
                        }
                    }
                }
            }
        });

        let pool_egress = pool.clone();
        let inbound_tx_egress = inbound_tx.clone();
        let shutdown_egress = shutdown.clone();
        tokio::spawn(async move {
            use futures::StreamExt;
            loop {
                let next = tokio::select! {
                    _ = shutdown_egress.cancelled() => break,
                    next = stack_stream.next() => next,
                };
                let Some(res) = next else {
                    break;
                };
                let frame = match res {
                    Ok(v) => v,
                    Err(e) => {
                        crate::log_error!("[SMOLTCP] Egress stream error: {e}");
                        continue;
                    }
                };
                let Some(mut pkt) = pool_egress.try_acquire() else {
                    continue;
                };
                if let Ok(dest) = pkt.extend_tail(frame.len()) {
                    dest.copy_from_slice(&frame);
                    if inbound_tx_egress.send(pkt).await.is_err() {
                        break;
                    }
                }
            }
        });

        let active_tcp = Arc::new(RwLock::new(HashMap::new()));
        let active_tcp_c = active_tcp.clone();
        let udp_verdicts = Arc::new(RwLock::new(VerdictCache::default()));

        if let Some(mut listener) = tcp_listener {
            let shutdown_listener = shutdown.clone();
            tokio::spawn(async move {
                use futures::StreamExt;
                loop {
                    let accepted = tokio::select! {
                        _ = shutdown_listener.cancelled() => break,
                        accepted = listener.next() => accepted,
                    };
                    let Some((mut client_stream, local_addr, remote_addr)) = accepted else {
                        break;
                    };
                    let key = (local_addr, remote_addr);
                    if let Ok(mut guard) = active_tcp_c.write() {
                        guard.insert(key, std::time::Instant::now());
                    }
                    let active_tcp_conn = active_tcp_c.clone();

                    tokio::spawn(async move {
                        let connect_res = tokio::time::timeout(
                            Duration::from_secs(5),
                            tokio::net::TcpStream::connect(remote_addr),
                        )
                        .await;

                        if let Ok(Ok(mut server_stream)) = connect_res {
                            let _ = server_stream.set_nodelay(true);
                            let sock_ref = SockRef::from(&server_stream);
                            let keepalive = socket2::TcpKeepalive::new()
                                .with_time(Duration::from_secs(30))
                                .with_interval(Duration::from_secs(10));
                            let _ = sock_ref.set_tcp_keepalive(&keepalive);
                            let _ = sock_ref.set_recv_buffer_size(262144);
                            let _ = sock_ref.set_send_buffer_size(262144);

                            let _ = tokio::io::copy_bidirectional_with_sizes(
                                &mut client_stream,
                                &mut server_stream,
                                65536,
                                65536,
                            )
                            .await;

                            use tokio::io::AsyncWriteExt;
                            let _ = tokio::time::timeout(
                                Duration::from_millis(300),
                                client_stream.shutdown(),
                            )
                            .await;
                            let _ = tokio::time::timeout(
                                Duration::from_millis(300),
                                server_stream.shutdown(),
                            )
                            .await;
                            drop(server_stream);
                        }

                        drop(client_stream);
                        if let Ok(mut guard) = active_tcp_conn.write() {
                            guard.remove(&key);
                        }
                    });
                }
            });
        }

        let active_tcp_cleanup = active_tcp.clone();
        let udp_verdicts_cleanup = udp_verdicts.clone();
        let shutdown_cleanup = shutdown.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(30));
            loop {
                tokio::select! {
                    _ = shutdown_cleanup.cancelled() => break,
                    _ = interval.tick() => {}
                }
                let now = std::time::Instant::now();
                if let Ok(mut guard) = active_tcp_cleanup.write() {
                    guard.retain(|_, last_seen| {
                        now.duration_since(*last_seen) < Duration::from_secs(120)
                    });
                }
                if let Ok(mut cache) = udp_verdicts_cleanup.write() {
                    cache.retain_fresh(now);
                }
            }
        });

        Ok(Self {
            domain_routing,
            direct_ips,
            dns_domain_map,
            pool,
            inbound_tx,
            direct_pkt_tx,
            active_tcp,
            udp_verdicts,
            udp_sessions: Arc::new(RwLock::new(HashMap::new())),
            shutdown,
            #[cfg(test)]
            udp_route_checkpoint: std::sync::Mutex::new(None),
            #[cfg(test)]
            udp_test_target: None,
            #[cfg(test)]
            learned_test_hooks,
        })
    }

    #[cfg(test)]
    async fn udp_route_checkpoint(&self, stage: UdpRouteCheckpointStage) {
        let checkpoint = self.udp_route_checkpoint.lock().ok().and_then(|mut point| {
            if point.as_ref().is_some_and(|point| point.stage == stage) {
                point.take()
            } else {
                None
            }
        });
        if let Some(point) = checkpoint {
            point.reached.notify_one();
            point.resume.notified().await;
        }
    }

    pub fn invalidate_route_caches(&self) {
        if let Ok(mut guard) = self.active_tcp.write() {
            guard.clear();
        }
        if let Ok(mut cache) = self.udp_verdicts.write() {
            cache.clear();
        }
    }

    pub fn sync_domain_routing(&self, config: &crate::dispatcher::DomainRoutingConfig) {
        self.update_routing_config(|_| config.clone());
    }

    pub(crate) fn update_routing_config(
        &self,
        update: impl FnOnce(
            &crate::dispatcher::DomainRoutingConfig,
        ) -> crate::dispatcher::DomainRoutingConfig,
    ) -> crate::dispatcher::DomainRoutingConfig {
        let origin = self.dns_domain_map.update_routing_config(
            &self.domain_routing,
            &self.direct_ips,
            update,
            |config| {
                self.invalidate_route_caches();
                // Each receive-loop keeps the origin of its socket. A new
                // config must not send fresh requests through an old-origin socket.
                if let Ok(mut guard) = self.udp_sessions.write() {
                    guard.clear();
                }
                if !config.enabled
                    && let Ok(mut guard) = self.active_tcp.write()
                {
                    guard.clear();
                }
            },
        );
        let config = (*origin.config).clone();
        if origin.changed && config.enabled {
            self.spawn_preresolve(origin, config.direct_domains.to_vec());
        }
        config
    }

    fn spawn_preresolve(&self, origin: crate::sni::RoutingLearningOrigin, domains: Vec<String>) {
        if !origin.config.enabled {
            return;
        }
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let ips_clone = self.direct_ips.clone();
            let dns_map_clone = self.dns_domain_map.clone();
            let routing_clone = self.domain_routing.clone();
            #[cfg(test)]
            let test_hooks = self.learned_test_hooks.clone();
            handle.spawn(async move {
                run_full_preresolve_task(
                    ips_clone,
                    dns_map_clone,
                    routing_clone,
                    origin,
                    domains,
                    #[cfg(test)]
                    test_hooks,
                )
                .await;
            });
        }
    }

    pub fn preresolve_domains(&self, domains: Vec<String>) {
        // A DNS refresh is not a config update. It captures the current epoch
        // rather than revoking unrelated observations and active DNS requests.
        let origin = self.dns_domain_map.routing_origin(&self.domain_routing);
        self.spawn_preresolve(origin, domains);
    }

    pub fn is_direct_ip(&self, ip: &IpAddr) -> bool {
        let _epoch = self.dns_domain_map.read_routing_epoch();
        self.direct_ips.load().contains(ip)
    }

    fn forward_direct_packet(&self, slice: &[u8]) {
        let _ = self.direct_pkt_tx.try_send(slice.to_vec());
    }

    pub async fn try_handle(&self, packet: &PacketBuf) -> bool {
        let origin = self.dns_domain_map.routing_origin(&self.domain_routing);
        let config = &origin.config;
        if !config.enabled && !config.ip_routing_enabled() {
            return false;
        }
        let slice = packet.as_slice();

        if let Some((domain, is_resp, _)) = crate::sni::parse_ip_packet_dns(slice)
            && !is_resp
        {
            let is_local_dns = crate::sni::extract_dst_addr(slice)
                .map(|a| is_local_or_private_ip(&a.ip()))
                .unwrap_or(false)
                || crate::sni::extract_src_addr(slice)
                    .map(|a| is_local_or_private_ip(&a.ip()))
                    .unwrap_or(false);
            if !is_local_dns {
                if config.enabled {
                    let is_direct = crate::sni::is_direct_domain_mode(
                        &domain,
                        config.is_whitelist,
                        &config.direct_domains,
                    );
                    if is_direct {
                        self.handle_dns_query(slice, &domain, true, &origin);
                        return true;
                    }
                } else if config.ip_routing_enabled() {
                    let is_tunnel_dns = if let Some(dst_addr) = crate::sni::extract_dst_addr(slice)
                    {
                        let dst_ip = dst_addr.ip();
                        if config.ip_is_whitelist {
                            config.ip_matches(&dst_ip)
                        } else {
                            !config.ip_matches(&dst_ip)
                        }
                    } else {
                        false
                    };
                    if !is_tunnel_dns {
                        self.handle_dns_query(slice, &domain, true, &origin);
                        return true;
                    }
                }
            }
            return false;
        }

        let Some(src_addr) = crate::sni::extract_src_addr(slice) else {
            return false;
        };
        let Some(dst_addr) = crate::sni::extract_dst_addr(slice) else {
            return false;
        };
        let dst_ip = dst_addr.ip();
        if dst_ip.is_unspecified()
            || dst_ip.is_loopback()
            || dst_ip.is_multicast()
            || is_local_or_private_ip(&dst_ip)
        {
            return false;
        }
        if let std::net::IpAddr::V4(v4) = dst_ip {
            let octets = v4.octets();
            if octets[0] == 0
                || octets[0] == 127
                || octets[0] >= 224
                || (octets[0] == 10 && octets[1] == 66 && octets[2] == 67)
            {
                return false;
            }
        }

        if slice.len() < 20 {
            return false;
        }
        let version = slice[0] >> 4;
        let protocol = match version {
            4 => slice[9],
            6 => {
                if slice.len() < 40 {
                    return false;
                }
                slice[6]
            }
            _ => return false,
        };

        if version == 4 && slice.len() >= 8 {
            let fragment_offset = (u16::from_be_bytes([slice[6], slice[7]]) & 0x1fff) * 8;
            if fragment_offset != 0 {
                return false;
            }
        }

        let key = (src_addr, dst_addr);

        if protocol == 6 {
            if self.direct_pkt_tx.is_closed() {
                return false;
            }
            let tcp_slice = match version {
                4 => {
                    let ihl = (slice[0] & 0x0f) as usize * 4;
                    if slice.len() < ihl + 14 {
                        return false;
                    }
                    &slice[ihl..]
                }
                6 => {
                    if slice.len() < 54 {
                        return false;
                    }
                    &slice[40..]
                }
                _ => return false,
            };
            let tcp_flags = tcp_slice[13];
            let is_tcp_syn = (tcp_flags & 0x02 != 0) && (tcp_flags & 0x10 == 0);
            if !is_tcp_syn {
                let is_active = if let Ok(guard) = self.active_tcp.read() {
                    guard.contains_key(&key)
                } else {
                    false
                };
                if is_active {
                    if self.direct_pkt_tx.is_closed() {
                        return false;
                    }
                    if let Ok(mut guard) = self.active_tcp.write() {
                        guard.insert(key, std::time::Instant::now());
                    }
                    self.forward_direct_packet(slice);
                    return true;
                }
                return false;
            }
        }

        if protocol == 17 {
            let verdict_key = VerdictKey {
                src: src_addr,
                dst: dst_addr,
                protocol,
            };
            let now = Instant::now();
            let (snapshot, cached) = {
                let epoch = self.dns_domain_map.read_routing_epoch();
                let Ok(cache) = self.udp_verdicts.read() else {
                    return false;
                };
                let origin = self
                    .dns_domain_map
                    .routing_origin_at(*epoch, &self.domain_routing);
                // Snapshot мог уже смениться, пока UPDATE_IPS ещё ждёт lock
                // для инвалидации. Не читаем verdict от прежней конфигурации.
                let cached = cache
                    .routing_config
                    .as_ref()
                    .filter(|cached_config| Arc::ptr_eq(cached_config, &origin.config))
                    .and_then(|_| cache.get(&verdict_key, now));
                (
                    UdpRouteSnapshot {
                        origin,
                        generation: cache.generation,
                    },
                    cached,
                )
            };
            #[cfg(test)]
            self.udp_route_checkpoint(UdpRouteCheckpointStage::Snapshot)
                .await;
            let direct = if let Some(verdict) = cached {
                matches!(verdict, crate::sni::RouteVerdict::Direct)
            } else {
                self.packet_is_direct(&snapshot.origin, &dst_ip)
            };
            #[cfg(test)]
            self.udp_route_checkpoint(UdpRouteCheckpointStage::Verdict)
                .await;
            {
                let epoch = self.dns_domain_map.read_routing_epoch();
                let Ok(mut cache) = self.udp_verdicts.write() else {
                    return false;
                };
                if !self.udp_snapshot_is_current(*epoch, &cache, &snapshot) {
                    return false;
                }
                if cached.is_none() {
                    if cache
                        .routing_config
                        .as_ref()
                        .is_none_or(|config| !Arc::ptr_eq(config, &snapshot.origin.config))
                    {
                        cache.entries.clear();
                        cache.routing_config = Some(snapshot.origin.config.clone());
                    }
                    cache.insert(
                        verdict_key,
                        if direct {
                            crate::sni::RouteVerdict::Direct
                        } else {
                            crate::sni::RouteVerdict::Tunnel
                        },
                        now,
                    );
                }
            }
            if !direct {
                return false;
            }
            return self
                .handle_direct_udp_packet(slice, src_addr, dst_addr, &snapshot)
                .await;
        }

        if protocol != 6 {
            return false;
        }

        if self.packet_is_direct(&origin, &dst_ip) {
            if let Ok(mut guard) = self.active_tcp.write() {
                guard.insert(key, std::time::Instant::now());
            }
            self.forward_direct_packet(slice);
            return true;
        }

        false
    }

    fn packet_is_direct(
        &self,
        origin: &crate::sni::RoutingLearningOrigin,
        dst_ip: &IpAddr,
    ) -> bool {
        let epoch = self.dns_domain_map.read_routing_epoch();
        if !origin.is_current(*epoch, &self.domain_routing) {
            return false;
        }
        let config = &origin.config;
        let domain = self.dns_domain_map.get(dst_ip);
        let verdict = crate::sni::evaluate_route(
            dst_ip,
            domain.as_deref(),
            config.enabled,
            config.is_whitelist,
            &config.direct_domains,
            config.ip_routing_enabled(),
            config.ip_is_whitelist,
            &config.ip_rules,
            &config.template_ip_rules,
        );
        if self.direct_ips.load().contains(dst_ip) {
            if config.ip_routing_enabled() && config.ip_is_whitelist && config.has_ip_rules() {
                !config.ip_matches(dst_ip)
            } else {
                true
            }
        } else {
            matches!(verdict, crate::sni::RouteVerdict::Direct)
        }
    }

    fn udp_snapshot_is_current(
        &self,
        epoch: u64,
        cache: &VerdictCache,
        snapshot: &UdpRouteSnapshot,
    ) -> bool {
        cache.generation == snapshot.generation
            && snapshot.origin.is_current(epoch, &self.domain_routing)
    }

    async fn handle_direct_udp_packet(
        &self,
        slice: &[u8],
        src_addr: SocketAddr,
        dst_addr: SocketAddr,
        snapshot: &UdpRouteSnapshot,
    ) -> bool {
        let version = slice[0] >> 4;
        let ihl = match version {
            4 => (slice[0] & 0x0f) as usize * 4,
            6 => 40,
            _ => return false,
        };
        if slice.len() < ihl + 8 {
            return false;
        }
        let udp_slice = &slice[ihl..];
        let udp_len = u16::from_be_bytes([udp_slice[4], udp_slice[5]]) as usize;
        if udp_len < 8 || udp_slice.len() < udp_len {
            return false;
        }
        let payload = &udp_slice[8..udp_len];

        let existing_sock = {
            let epoch = self.dns_domain_map.read_routing_epoch();
            if !snapshot.origin.is_current(*epoch, &self.domain_routing) {
                return false;
            }
            if let Ok(guard) = self.udp_sessions.read() {
                guard.get(&src_addr).cloned()
            } else {
                None
            }
        };

        let sock = if let Some(s) = existing_sock {
            s
        } else {
            let bind_addr = if dst_addr.is_ipv6() {
                "[::]:0"
            } else {
                "0.0.0.0:0"
            };
            let Ok(new_sock) = tokio::net::UdpSocket::bind(bind_addr).await else {
                return false;
            };
            let socket_ref = socket2::SockRef::from(&new_sock);
            let _ = socket_ref.set_recv_buffer_size(262144);
            let _ = socket_ref.set_send_buffer_size(262144);
            let new_sock = Arc::new(new_sock);

            let epoch = self.dns_domain_map.read_routing_epoch();
            if !snapshot.origin.is_current(*epoch, &self.domain_routing) {
                return false;
            }
            let mut guard = match self.udp_sessions.write() {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
            let registered = if let Some(existing) = guard.get(&src_addr).cloned() {
                Some(existing)
            } else if guard.len() >= MAX_UDP_SESSIONS {
                return false;
            } else {
                guard.insert(src_addr, new_sock.clone());
                None
            };

            match registered {
                Some(existing) => existing,
                None => {
                    let sock_clone = new_sock.clone();
                    let inbound_tx = self.inbound_tx.clone();
                    let pool = self.pool.clone();
                    let sessions = self.udp_sessions.clone();
                    let dns_map_clone = self.dns_domain_map.clone();
                    let ips_clone = self.direct_ips.clone();
                    let routing_clone = self.domain_routing.clone();
                    let socket_origin = snapshot.origin.clone();
                    let client_addr = src_addr;
                    let shutdown = self.shutdown.clone();
                    #[cfg(test)]
                    let test_hooks = self.learned_test_hooks.clone();

                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 65536];
                        loop {
                            let recv_res = tokio::select! {
                                _ = shutdown.cancelled() => break,
                                recv_res = tokio::time::timeout(
                                    Duration::from_secs(120),
                                    sock_clone.recv_from(&mut buf),
                                ) => recv_res,
                            };

                            match recv_res {
                                Ok(Ok((len, remote_addr))) => {
                                    let is_dns = remote_addr.port() == 53;
                                    #[cfg(test)]
                                    let is_dns = is_dns
                                        || test_hooks
                                            .upstreams
                                            .lock()
                                            .ok()
                                            .and_then(|values| values.clone())
                                            .is_some_and(|values| values.contains(&remote_addr));
                                    #[cfg(test)]
                                    let mut _test_completion = None;
                                    if is_dns
                                        && let Some((domain, _, ips)) =
                                            crate::sni::extract_dns_info(&buf[..len])
                                        && !ips.is_empty()
                                    {
                                        #[cfg(test)]
                                        {
                                            _test_completion = test_hooks
                                                .pause(
                                                    LearnedCheckpointStage::UdpReplyBeforeCommit,
                                                    &domain,
                                                )
                                                .await;
                                        }
                                        dns_map_clone.publish_routing_learning(
                                            &routing_clone,
                                            &ips_clone,
                                            &socket_origin,
                                            &domain,
                                            &ips,
                                            false,
                                        );
                                    }
                                    let udp_len = 8 + len;
                                    let ip_header_len = if remote_addr.is_ipv6() { 40 } else { 20 };
                                    let total_len = ip_header_len + udp_len;
                                    let Some(mut pkt) = pool.try_acquire() else {
                                        continue;
                                    };
                                    if let Ok(dest) = pkt.extend_tail(total_len)
                                        && craft_udp_packet_into(
                                            remote_addr,
                                            client_addr,
                                            &buf[..len],
                                            dest,
                                        )
                                    {
                                        let _ = inbound_tx.send(pkt).await;
                                    }
                                }
                                Ok(Err(ref e))
                                    if e.kind() == std::io::ErrorKind::Interrupted
                                        || e.kind() == std::io::ErrorKind::WouldBlock
                                        || e.kind() == std::io::ErrorKind::ConnectionRefused =>
                                {
                                    continue;
                                }
                                _ => break,
                            }
                        }
                        if let Ok(mut guard) = sessions.write() {
                            let is_current = guard
                                .get(&client_addr)
                                .is_some_and(|current| Arc::ptr_eq(current, &sock_clone));
                            if is_current {
                                guard.remove(&client_addr);
                            }
                        }
                    });

                    new_sock
                }
            }
        };

        #[cfg(test)]
        self.udp_route_checkpoint(UdpRouteCheckpointStage::Send)
            .await;
        #[cfg(test)]
        let dst_addr = self.udp_test_target.unwrap_or(dst_addr);
        loop {
            if sock.writable().await.is_err() {
                return false;
            }
            let sent = {
                let epoch = self.dns_domain_map.read_routing_epoch();
                let Ok(cache) = self.udp_verdicts.read() else {
                    return false;
                };
                if !self.udp_snapshot_is_current(*epoch, &cache, snapshot) {
                    return false;
                }
                // Не держим sync-lock через await. Проверка и syscall под одним
                // epoch/read-lock: завершённое обновление не допускает старый send,
                // в том числе после ожидания bind/writable.
                sock.try_send_to(payload, dst_addr)
            };
            match sent {
                Ok(_) => return true,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return false,
            }
        }
    }

    fn handle_dns_query(
        &self,
        slice: &[u8],
        domain: &str,
        is_direct: bool,
        origin: &crate::sni::RoutingLearningOrigin,
    ) {
        let Some(src_addr) = crate::sni::extract_src_addr(slice) else {
            return;
        };
        let Some(dst_addr) = crate::sni::extract_dst_addr(slice) else {
            return;
        };
        let version = slice[0] >> 4;
        let ihl = match version {
            4 => (slice[0] & 0x0f) as usize * 4,
            6 => 40,
            _ => return,
        };
        if slice.len() < ihl + 8 {
            return;
        }
        let udp_len = u16::from_be_bytes([slice[ihl + 4], slice[ihl + 5]]) as usize;
        let total_end = (ihl + udp_len).min(slice.len());
        if total_end < ihl + 8 {
            return;
        }
        let query_payload = slice[ihl + 8..total_end].to_vec();

        let direct_ips = self.direct_ips.clone();
        let dns_domain_map = self.dns_domain_map.clone();
        let domain_routing = self.domain_routing.clone();
        let origin = origin.clone();
        let inbound_tx = self.inbound_tx.clone();
        let pool = self.pool.clone();
        let domain_name = domain.to_string();
        #[cfg(test)]
        let test_hooks = self.learned_test_hooks.clone();

        let Ok(permit) = dns_query_slots().clone().try_acquire_owned() else {
            return;
        };

        tokio::spawn(async move {
            let _permit = permit;
            let socket = match tokio::net::UdpSocket::bind("0.0.0.0:0").await {
                Ok(s) => s,
                Err(_) => return,
            };
            let upstreams = [
                SocketAddr::new(IpAddr::V4(Ipv4Addr::new(77, 88, 8, 8)), 53),
                SocketAddr::new(IpAddr::V4(Ipv4Addr::new(77, 88, 8, 1)), 53),
                SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 53),
                SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53),
            ];
            #[cfg(test)]
            let upstreams = test_hooks
                .upstreams
                .lock()
                .ok()
                .and_then(|upstreams| upstreams.clone())
                .unwrap_or_else(|| upstreams.to_vec());
            let mut resp_buf = [0u8; 4096];
            let mut resp_len = 0;

            for &upstream in &upstreams {
                if socket.send_to(&query_payload, upstream).await.is_ok()
                    && let Ok(Ok((n, _))) = tokio::time::timeout(
                        Duration::from_millis(600),
                        socket.recv_from(&mut resp_buf),
                    )
                    .await
                {
                    resp_len = n;
                    break;
                }
            }

            if resp_len == 0 {
                return;
            }

            let resp_slice = &resp_buf[..resp_len];
            #[cfg(test)]
            let _test_completion = test_hooks
                .pause(LearnedCheckpointStage::DnsReplyBeforeCommit, &domain_name)
                .await;
            if let Some((_, _, ips)) = crate::sni::extract_dns_info(resp_slice)
                && !ips.is_empty()
            {
                dns_domain_map.publish_routing_learning(
                    &domain_routing,
                    &direct_ips,
                    &origin,
                    &domain_name,
                    &ips,
                    is_direct,
                );
            }

            let udp_len = 8 + resp_len;
            let ip_header_len = if dst_addr.is_ipv6() { 40 } else { 20 };
            let total_len = ip_header_len + udp_len;
            let Some(mut pkt) = pool.try_acquire() else {
                return;
            };
            if let Ok(dest_slice) = pkt.extend_tail(total_len)
                && craft_udp_packet_into(dst_addr, src_addr, resp_slice, dest_slice)
            {
                let _ = inbound_tx.send(pkt).await;
            }
        });
    }
}

pub fn craft_tcp_packet_into(
    src: SocketAddr,
    dst: SocketAddr,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: &[u8],
    buf: &mut [u8],
) -> bool {
    let has_syn = (flags & 0x02) != 0;
    let tcp_header_len = if has_syn { 24 } else { 20 };
    match (src, dst) {
        (SocketAddr::V4(src_v4), SocketAddr::V4(dst_v4)) => {
            let total_len = 20 + tcp_header_len + payload.len();
            if buf.len() < total_len {
                return false;
            }
            buf[0] = 0x45;
            buf[1] = 0x00;
            buf[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
            buf[4..6].copy_from_slice(&0x1234u16.to_be_bytes());
            buf[6..8].copy_from_slice(&0x4000u16.to_be_bytes());
            buf[8] = 64;
            buf[9] = 6;
            buf[10..12].copy_from_slice(&[0, 0]);
            buf[12..16].copy_from_slice(&src_v4.ip().octets());
            buf[16..20].copy_from_slice(&dst_v4.ip().octets());
            let ip_csum = ip_checksum(&buf[..20]);
            buf[10..12].copy_from_slice(&ip_csum.to_be_bytes());

            let tcp_start = 20;
            buf[tcp_start..tcp_start + 2].copy_from_slice(&src_v4.port().to_be_bytes());
            buf[tcp_start + 2..tcp_start + 4].copy_from_slice(&dst_v4.port().to_be_bytes());
            buf[tcp_start + 4..tcp_start + 8].copy_from_slice(&seq.to_be_bytes());
            buf[tcp_start + 8..tcp_start + 12].copy_from_slice(&ack.to_be_bytes());
            buf[tcp_start + 12] = if has_syn { 0x60 } else { 0x50 };
            buf[tcp_start + 13] = flags;
            buf[tcp_start + 14..tcp_start + 16].copy_from_slice(&65535u16.to_be_bytes());
            buf[tcp_start + 16..tcp_start + 18].copy_from_slice(&[0, 0]);
            buf[tcp_start + 18..tcp_start + 20].copy_from_slice(&[0, 0]);
            if has_syn {
                buf[tcp_start + 20..tcp_start + 24].copy_from_slice(&[0x02, 0x04, 0x04, 0x00]);
            }
            if !payload.is_empty() {
                buf[tcp_start + tcp_header_len..total_len].copy_from_slice(payload);
            }
            let tcp_csum = tcp_checksum_v4(*src_v4.ip(), *dst_v4.ip(), &buf[tcp_start..total_len]);
            buf[tcp_start + 16..tcp_start + 18].copy_from_slice(&tcp_csum.to_be_bytes());
            true
        }
        (SocketAddr::V6(src_v6), SocketAddr::V6(dst_v6)) => {
            let payload_len = tcp_header_len + payload.len();
            let total_len = 40 + payload_len;
            if buf.len() < total_len {
                return false;
            }
            buf[0] = 0x60;
            buf[1..4].copy_from_slice(&[0, 0, 0]);
            buf[4..6].copy_from_slice(&(payload_len as u16).to_be_bytes());
            buf[6] = 6;
            buf[7] = 64;
            buf[8..24].copy_from_slice(&src_v6.ip().octets());
            buf[24..40].copy_from_slice(&dst_v6.ip().octets());

            let tcp_start = 40;
            buf[tcp_start..tcp_start + 2].copy_from_slice(&src_v6.port().to_be_bytes());
            buf[tcp_start + 2..tcp_start + 4].copy_from_slice(&dst_v6.port().to_be_bytes());
            buf[tcp_start + 4..tcp_start + 8].copy_from_slice(&seq.to_be_bytes());
            buf[tcp_start + 8..tcp_start + 12].copy_from_slice(&ack.to_be_bytes());
            buf[tcp_start + 12] = if has_syn { 0x60 } else { 0x50 };
            buf[tcp_start + 13] = flags;
            buf[tcp_start + 14..tcp_start + 16].copy_from_slice(&65535u16.to_be_bytes());
            buf[tcp_start + 16..tcp_start + 18].copy_from_slice(&[0, 0]);
            buf[tcp_start + 18..tcp_start + 20].copy_from_slice(&[0, 0]);
            if has_syn {
                buf[tcp_start + 20..tcp_start + 24].copy_from_slice(&[0x02, 0x04, 0x04, 0x00]);
            }
            if !payload.is_empty() {
                buf[tcp_start + tcp_header_len..total_len].copy_from_slice(payload);
            }
            let tcp_csum = tcp_checksum_v6(*src_v6.ip(), *dst_v6.ip(), &buf[tcp_start..total_len]);
            buf[tcp_start + 16..tcp_start + 18].copy_from_slice(&tcp_csum.to_be_bytes());
            true
        }
        _ => false,
    }
}

pub fn craft_udp_packet_into(
    src: SocketAddr,
    dst: SocketAddr,
    payload: &[u8],
    buf: &mut [u8],
) -> bool {
    match (src, dst) {
        (SocketAddr::V4(src_v4), SocketAddr::V4(dst_v4)) => {
            let udp_len = 8 + payload.len();
            let total_len = 20 + udp_len;
            if buf.len() < total_len {
                return false;
            }
            buf[0] = 0x45;
            buf[1] = 0x00;
            buf[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
            buf[4..6].copy_from_slice(&0x2345u16.to_be_bytes());
            buf[6..8].copy_from_slice(&0x4000u16.to_be_bytes());
            buf[8] = 64;
            buf[9] = 17;
            buf[10..12].copy_from_slice(&[0, 0]);
            buf[12..16].copy_from_slice(&src_v4.ip().octets());
            buf[16..20].copy_from_slice(&dst_v4.ip().octets());
            let ip_csum = ip_checksum(&buf[..20]);
            buf[10..12].copy_from_slice(&ip_csum.to_be_bytes());

            let udp_start = 20;
            buf[udp_start..udp_start + 2].copy_from_slice(&src_v4.port().to_be_bytes());
            buf[udp_start + 2..udp_start + 4].copy_from_slice(&dst_v4.port().to_be_bytes());
            buf[udp_start + 4..udp_start + 6].copy_from_slice(&(udp_len as u16).to_be_bytes());
            buf[udp_start + 6..udp_start + 8].copy_from_slice(&[0, 0]);
            buf[udp_start + 8..total_len].copy_from_slice(payload);
            let udp_csum = udp_checksum_v4(*src_v4.ip(), *dst_v4.ip(), &buf[udp_start..total_len]);
            buf[udp_start + 6..udp_start + 8].copy_from_slice(&udp_csum.to_be_bytes());
            true
        }
        (SocketAddr::V6(src_v6), SocketAddr::V6(dst_v6)) => {
            let udp_len = 8 + payload.len();
            let total_len = 40 + udp_len;
            if buf.len() < total_len {
                return false;
            }
            buf[0] = 0x60;
            buf[1..4].copy_from_slice(&[0, 0, 0]);
            buf[4..6].copy_from_slice(&(udp_len as u16).to_be_bytes());
            buf[6] = 17;
            buf[7] = 64;
            buf[8..24].copy_from_slice(&src_v6.ip().octets());
            buf[24..40].copy_from_slice(&dst_v6.ip().octets());

            let udp_start = 40;
            buf[udp_start..udp_start + 2].copy_from_slice(&src_v6.port().to_be_bytes());
            buf[udp_start + 2..udp_start + 4].copy_from_slice(&dst_v6.port().to_be_bytes());
            buf[udp_start + 4..udp_start + 6].copy_from_slice(&(udp_len as u16).to_be_bytes());
            buf[udp_start + 6..udp_start + 8].copy_from_slice(&[0, 0]);
            buf[udp_start + 8..total_len].copy_from_slice(payload);
            let udp_csum = udp_checksum_v6(*src_v6.ip(), *dst_v6.ip(), &buf[udp_start..total_len]);
            buf[udp_start + 6..udp_start + 8].copy_from_slice(&udp_csum.to_be_bytes());
            true
        }
        _ => false,
    }
}

pub fn build_tcp_packet(
    src: SocketAddr,
    dst: SocketAddr,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: &[u8],
) -> Option<Vec<u8>> {
    let has_syn = (flags & 0x02) != 0;
    let tcp_header_len = if has_syn { 24 } else { 20 };
    let ip_header_len = if src.is_ipv6() { 40 } else { 20 };
    let total_len = ip_header_len + tcp_header_len + payload.len();
    let mut buf = vec![0u8; total_len];
    if craft_tcp_packet_into(src, dst, seq, ack, flags, payload, &mut buf) {
        Some(buf)
    } else {
        None
    }
}

pub fn build_udp_packet(src: SocketAddr, dst: SocketAddr, payload: &[u8]) -> Option<Vec<u8>> {
    let udp_len = 8 + payload.len();
    let ip_header_len = if src.is_ipv6() { 40 } else { 20 };
    let total_len = ip_header_len + udp_len;
    let mut buf = vec![0u8; total_len];
    if craft_udp_packet_into(src, dst, payload, &mut buf) {
        Some(buf)
    } else {
        None
    }
}

pub fn ip_checksum(header: &[u8]) -> u16 {
    let mut sum = 0u32;
    for chunk in header.chunks_exact(2) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

pub fn tcp_checksum_v4(src_ip: Ipv4Addr, dst_ip: Ipv4Addr, tcp_segment: &[u8]) -> u16 {
    let mut sum = 0u32;
    let src_oct = src_ip.octets();
    sum += u16::from_be_bytes([src_oct[0], src_oct[1]]) as u32;
    sum += u16::from_be_bytes([src_oct[2], src_oct[3]]) as u32;
    let dst_oct = dst_ip.octets();
    sum += u16::from_be_bytes([dst_oct[0], dst_oct[1]]) as u32;
    sum += u16::from_be_bytes([dst_oct[2], dst_oct[3]]) as u32;
    sum += 6u32;
    sum += tcp_segment.len() as u32;

    let mut chunks = tcp_segment.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    if let Some(&rem) = chunks.remainder().first() {
        sum += (rem as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

pub fn tcp_checksum_v6(src_ip: Ipv6Addr, dst_ip: Ipv6Addr, tcp_segment: &[u8]) -> u16 {
    let mut sum = 0u32;
    let src_oct = src_ip.octets();
    for chunk in src_oct.chunks_exact(2) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    let dst_oct = dst_ip.octets();
    for chunk in dst_oct.chunks_exact(2) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    sum += (tcp_segment.len() as u32) >> 16;
    sum += (tcp_segment.len() as u32) & 0xffff;
    sum += 6u32;

    let mut chunks = tcp_segment.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    if let Some(&rem) = chunks.remainder().first() {
        sum += (rem as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

pub fn udp_checksum_v4(src_ip: Ipv4Addr, dst_ip: Ipv4Addr, udp_segment: &[u8]) -> u16 {
    let mut sum = 0u32;
    let src_oct = src_ip.octets();
    sum += u16::from_be_bytes([src_oct[0], src_oct[1]]) as u32;
    sum += u16::from_be_bytes([src_oct[2], src_oct[3]]) as u32;
    let dst_oct = dst_ip.octets();
    sum += u16::from_be_bytes([dst_oct[0], dst_oct[1]]) as u32;
    sum += u16::from_be_bytes([dst_oct[2], dst_oct[3]]) as u32;
    sum += 17u32;
    sum += udp_segment.len() as u32;

    let mut chunks = udp_segment.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    if let Some(&rem) = chunks.remainder().first() {
        sum += (rem as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    let res = !(sum as u16);
    if res == 0 { 0xffff } else { res }
}

pub fn udp_checksum_v6(src_ip: Ipv6Addr, dst_ip: Ipv6Addr, udp_segment: &[u8]) -> u16 {
    let mut sum = 0u32;
    let src_oct = src_ip.octets();
    for chunk in src_oct.chunks_exact(2) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    let dst_oct = dst_ip.octets();
    for chunk in dst_oct.chunks_exact(2) {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    sum += (udp_segment.len() as u32) >> 16;
    sum += (udp_segment.len() as u32) & 0xffff;
    sum += 17u32;

    let mut chunks = udp_segment.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    if let Some(&rem) = chunks.remainder().first() {
        sum += (rem as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    let res = !(sum as u16);
    if res == 0 { 0xffff } else { res }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ip_checksum_computation() {
        let mut hdr = [
            0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xac, 0x10,
            0x0a, 0x63, 0xac, 0x10, 0x0a, 0x0c,
        ];
        let csum = ip_checksum(&hdr);
        assert_eq!(csum, 0xb1e6);
        hdr[10..12].copy_from_slice(&csum.to_be_bytes());
        let verified = ip_checksum(&hdr);
        assert_eq!(verified, 0);
    }

    #[test]
    fn test_tcp_packet_construction() {
        let src: SocketAddr = "10.0.0.2:54321".parse().unwrap();
        let dst: SocketAddr = "77.88.55.60:443".parse().unwrap();
        let pkt = build_tcp_packet(src, dst, 1000, 2000, 0x12, b"test").unwrap();
        assert_eq!(pkt[0], 0x45);
        assert_eq!(pkt[9], 6);
        let dst_extracted = crate::sni::extract_dst_addr(&pkt).unwrap();
        assert_eq!(dst_extracted, dst);
        let src_extracted = crate::sni::extract_src_addr(&pkt).unwrap();
        assert_eq!(src_extracted, src);
    }

    #[test]
    fn test_udp_packet_construction() {
        let src: SocketAddr = "77.88.8.8:53".parse().unwrap();
        let dst: SocketAddr = "10.0.0.2:12345".parse().unwrap();
        let pkt = build_udp_packet(src, dst, b"dns_data").unwrap();
        assert_eq!(pkt[0], 0x45);
        assert_eq!(pkt[9], 17);
        let dst_extracted = crate::sni::extract_dst_addr(&pkt).unwrap();
        assert_eq!(dst_extracted, dst);
        let src_extracted = crate::sni::extract_src_addr(&pkt).unwrap();
        assert_eq!(src_extracted, src);
    }

    #[tokio::test]
    async fn preresolve_without_supplied_domains_does_not_seed_a_template() {
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                ..Default::default()
            },
        ));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let origin = dns_domain_map.routing_origin(&domain_routing);
        run_full_preresolve_task(
            direct_ips.clone(),
            dns_domain_map,
            domain_routing,
            origin,
            vec![],
            Arc::new(LearnedTestHooks::default()),
        )
        .await;
        assert!(direct_ips.load().is_empty());
    }

    #[tokio::test]
    async fn test_smoltcp_direct_tcp_syn() {
        smoltcp_syn_gets_syn_ack(Duration::ZERO).await;
    }

    // An idle stack with no socket waits only on its notify (no 5 ms re-poll): the first SYN after a quiet spell must
    // still wake it.
    #[tokio::test]
    async fn test_smoltcp_direct_tcp_syn_after_idle() {
        smoltcp_syn_gets_syn_ack(Duration::from_millis(300)).await;
    }

    async fn smoltcp_syn_gets_syn_ack(idle: Duration) {
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                is_whitelist: false,
                direct_domains: vec!["example.com".to_string()].into(),
                ip_is_whitelist: false,
                ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
                template_ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
            },
        ));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(64);
        let (inbound_tx, mut inbound_rx) = mpsc::channel(64);

        let relay = DirectRelay::new(
            domain_routing,
            direct_ips,
            dns_domain_map,
            pool.clone(),
            inbound_tx,
        )
        .expect("smoltcp test stack must initialize");

        let src: SocketAddr = "10.66.67.2:54321".parse().unwrap();
        let dst: SocketAddr = "93.184.216.34:80".parse().unwrap();
        relay
            .direct_ips
            .store(Arc::new(std::iter::once(dst.ip()).collect()));

        tokio::time::sleep(idle).await;
        let syn_raw = build_tcp_packet(src, dst, 1000, 0, 0x02, &[]).unwrap();
        let mut pkt = pool.try_acquire().unwrap();
        pkt.extend_tail(syn_raw.len())
            .unwrap()
            .copy_from_slice(&syn_raw);

        let handled = relay.try_handle(&pkt).await;
        assert!(handled);

        let resp = tokio::time::timeout(Duration::from_millis(1000), inbound_rx.recv()).await;
        assert!(resp.is_ok(), "Expected SYN-ACK response from smoltcp stack");
        let resp_pkt = resp.unwrap().unwrap();
        let resp_slice = resp_pkt.as_slice();
        assert_eq!(resp_slice[9], 6);
        let flags = resp_slice[33];
        assert_eq!(flags & 0x12, 0x12, "Expected SYN-ACK flags (0x12)");
    }

    #[tokio::test]
    async fn test_direct_relay_active_tcp_cleanup_purge() {
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig::default(),
        ));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(16);
        let (inbound_tx, _inbound_rx) = mpsc::channel(64);
        let relay = DirectRelay::new(domain_routing, direct_ips, dns_domain_map, pool, inbound_tx)
            .expect("smoltcp test stack must initialize");
        let k1: (SocketAddr, SocketAddr) = (
            "10.0.0.1:1000".parse().unwrap(),
            "1.1.1.1:80".parse().unwrap(),
        );
        let k2: (SocketAddr, SocketAddr) = (
            "10.0.0.2:2000".parse().unwrap(),
            "2.2.2.2:80".parse().unwrap(),
        );
        let now = std::time::Instant::now();
        {
            let mut guard = relay.active_tcp.write().unwrap();
            guard.insert(k1, now - Duration::from_secs(130));
            guard.insert(k2, now - Duration::from_secs(10));
        }
        {
            let mut guard = relay.active_tcp.write().unwrap();
            guard.retain(|_, last_seen| now.duration_since(*last_seen) < Duration::from_secs(120));
        }
        let guard = relay.active_tcp.read().unwrap();
        assert!(!guard.contains_key(&k1));
        assert!(guard.contains_key(&k2));
    }

    #[tokio::test]
    async fn test_direct_relay_malformed_packets_rejected_safely() {
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                is_whitelist: false,
                direct_domains: vec!["example.com".to_string()].into(),
                ip_is_whitelist: false,
                ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
                template_ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
            },
        ));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(16);
        let (inbound_tx, _inbound_rx) = mpsc::channel(64);
        let relay = DirectRelay::new(
            domain_routing,
            direct_ips,
            dns_domain_map,
            pool.clone(),
            inbound_tx,
        )
        .expect("smoltcp test stack must initialize");

        let empty_pkt = pool.try_acquire().unwrap();
        assert!(!relay.try_handle(&empty_pkt).await);

        for len in 1..20 {
            let mut short_pkt = pool.try_acquire().unwrap();
            let mut buf = vec![0u8; len];
            buf[0] = 0x45;
            short_pkt.extend_tail(len).unwrap().copy_from_slice(&buf);
            assert!(!relay.try_handle(&short_pkt).await);
        }

        let mut bad_ver = pool.try_acquire().unwrap();
        let mut buf = vec![0u8; 40];
        buf[0] = 0x25;
        bad_ver.extend_tail(40).unwrap().copy_from_slice(&buf);
        assert!(!relay.try_handle(&bad_ver).await);
    }

    #[tokio::test]
    async fn test_direct_relay_bypasses_icmp_cleanly() {
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                is_whitelist: false,
                direct_domains: vec!["example.com".to_string()].into(),
                ip_is_whitelist: false,
                ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
                template_ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
            },
        ));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(16);
        let (inbound_tx, _inbound_rx) = mpsc::channel(64);
        let relay = DirectRelay::new(
            domain_routing,
            direct_ips,
            dns_domain_map,
            pool.clone(),
            inbound_tx,
        )
        .expect("smoltcp test stack must initialize");

        let target_ip: IpAddr = "93.184.216.34".parse().unwrap();
        relay
            .direct_ips
            .store(Arc::new(std::iter::once(target_ip).collect()));

        let mut icmp_pkt = pool.try_acquire().unwrap();
        let mut buf = vec![0u8; 64];
        buf[0] = 0x45;
        buf[2..4].copy_from_slice(&64u16.to_be_bytes());
        buf[8] = 64;
        buf[9] = 1;
        buf[12..16].copy_from_slice(&[10, 66, 67, 2]);
        buf[16..20].copy_from_slice(&[93, 184, 216, 34]);
        buf[20] = 8;
        buf[21] = 0;
        icmp_pkt.extend_tail(64).unwrap().copy_from_slice(&buf);

        let handled = relay.try_handle(&icmp_pkt).await;
        assert!(!handled);
    }

    #[test]
    fn repeated_udp_packets_read_the_cached_verdict() {
        let mut cache = VerdictCache::default();
        let mut evaluations = 0;
        let key = VerdictKey {
            src: "10.0.0.1:5000".parse().unwrap(),
            dst: "8.8.8.8:53".parse().unwrap(),
            protocol: 17,
        };
        let now = Instant::now();
        for _ in 0..5 {
            if cache.get(&key, now).is_none() {
                evaluations += 1;
                cache.insert(key, crate::sni::RouteVerdict::Tunnel, now);
            }
        }
        assert_eq!(evaluations, 1);
    }

    #[test]
    fn udp_verdict_is_invisible_to_tcp() {
        let mut cache = VerdictCache::default();
        let udp = VerdictKey {
            src: "10.0.0.1:5000".parse().unwrap(),
            dst: "8.8.8.8:443".parse().unwrap(),
            protocol: 17,
        };
        let tcp = VerdictKey { protocol: 6, ..udp };
        let now = Instant::now();
        cache.insert(udp, crate::sni::RouteVerdict::Direct, now);
        assert_eq!(cache.get(&udp, now), Some(crate::sni::RouteVerdict::Direct));
        assert_eq!(cache.get(&tcp, now), None);
    }

    #[test]
    fn a_stale_udp_verdict_is_recomputed() {
        let mut cache = VerdictCache::default();
        let key = VerdictKey {
            src: "10.0.0.1:5000".parse().unwrap(),
            dst: "8.8.8.8:53".parse().unwrap(),
            protocol: 17,
        };
        let now = Instant::now();
        cache.insert(
            key,
            crate::sni::RouteVerdict::Direct,
            now - Duration::from_secs(130),
        );
        assert_eq!(cache.get(&key, now), None);
    }

    #[test]
    fn udp_verdict_cache_is_bounded() {
        let mut cache = VerdictCache::default();
        let now = Instant::now();
        for index in 0..(MAX_UDP_VERDICTS + 100) {
            cache.insert(verdict_key(index), crate::sni::RouteVerdict::Tunnel, now);
        }
        assert!(cache.len() <= MAX_UDP_VERDICTS);
    }

    fn verdict_key(index: usize) -> VerdictKey {
        let index = index as u32;
        VerdictKey {
            src: SocketAddr::from((
                [10, (index >> 16) as u8, (index >> 8) as u8, index as u8],
                1000,
            )),
            dst: SocketAddr::from(([8, 8, 8, 8], 53)),
            protocol: 17,
        }
    }

    fn test_relay_with_config(
        config: crate::dispatcher::DomainRoutingConfig,
    ) -> (DirectRelay, Arc<PacketPool>) {
        let domain_routing = Arc::new(ArcSwap::from_pointee(config));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(64);
        let (inbound_tx, _inbound_rx) = mpsc::channel(64);
        let relay = DirectRelay::new(
            domain_routing,
            direct_ips,
            dns_domain_map,
            pool.clone(),
            inbound_tx,
        )
        .expect("smoltcp test stack must initialize");
        (relay, pool)
    }

    const LEARNED_A: &str = "a.routing.example";
    const LEARNED_B: &str = "b.routing.example";

    struct LearnedFixture {
        relay: Arc<DirectRelay>,
        dispatcher: Arc<crate::dispatcher::Dispatcher>,
        pool: Arc<PacketPool>,
        observer: tokio::net::UdpSocket,
        inbound: mpsc::Receiver<PacketBuf>,
    }

    async fn learned_fixture() -> LearnedFixture {
        let routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig::default(),
        ));
        let ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns = Arc::new(crate::sni::DnsDomainMap::default());
        let pool = PacketPool::new(64);
        let (inbound_tx, inbound) = mpsc::channel(64);
        let observer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut relay = DirectRelay::new(
            routing.clone(),
            ips.clone(),
            dns.clone(),
            pool.clone(),
            inbound_tx,
        )
        .unwrap();
        relay.udp_test_target = Some(observer.local_addr().unwrap());
        relay.learned_test_hooks.set_resolutions(HashMap::from([
            (LEARNED_A.to_owned(), vec!["93.184.216.34".parse().unwrap()]),
            (LEARNED_B.to_owned(), vec!["1.1.1.1".parse().unwrap()]),
        ]));
        let relay = Arc::new(relay);
        let dispatcher = crate::dispatcher::Dispatcher::routing_test_dispatcher(
            routing,
            ips,
            dns,
            relay.clone(),
            pool.clone(),
        );
        LearnedFixture {
            relay,
            dispatcher,
            pool,
            observer,
            inbound,
        }
    }

    async fn learned_notification(notify: &tokio::sync::Notify) {
        tokio::time::timeout(Duration::from_secs(2), notify.notified())
            .await
            .unwrap();
    }

    fn template_blob(text: &str) -> (String, String) {
        use base64::Engine;
        use flate2::Compression;
        use flate2::write::GzEncoder;
        use sha2::Digest;
        use std::io::Write;
        let sha = sha2::Sha256::digest(text.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(text.as_bytes()).unwrap();
        let blob = base64::engine::general_purpose::STANDARD.encode(encoder.finish().unwrap());
        (sha, blob)
    }

    fn learned_packet(pool: &Arc<PacketPool>, raw: &[u8]) -> PacketBuf {
        let mut packet = pool.try_acquire().unwrap();
        packet.extend_tail(raw.len()).unwrap().copy_from_slice(raw);
        packet
    }

    impl LearnedFixture {
        async fn update(&self, domain: &str) {
            let (reached, resume, done) = self
                .relay
                .learned_test_hooks
                .checkpoint(LearnedCheckpointStage::PreresolveBeforeCommit, domain);
            self.dispatcher
                .update_domain_routing(&format!("enabled=1;domains={domain}"));
            learned_notification(&reached).await;
            resume.notify_one();
            learned_notification(&done).await;
        }

        async fn assert_udp_tunnels(&self, ip: IpAddr) {
            let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
            let dst = SocketAddr::new(ip, 5000);
            let raw = build_udp_packet(src, dst, b"stale-learning").unwrap();
            let handled = self
                .relay
                .try_handle(&learned_packet(&self.pool, &raw))
                .await;
            let mut received = [0u8; 32];
            let sent = tokio::time::timeout(
                Duration::from_millis(50),
                self.observer.recv_from(&mut received),
            )
            .await
            .is_ok();
            assert!(!sent, "stale learned data sent UDP directly to {ip}");
            assert!(
                !handled,
                "stale learned data consumed the tunnel fallback for {ip}"
            );
            assert_eq!(
                self.relay.routing_test_udp_verdict(src, dst),
                Some(crate::sni::RouteVerdict::Tunnel)
            );
        }
    }

    fn learned_dns_wire(domain: &str, answer: Option<Ipv4Addr>) -> Vec<u8> {
        let mut wire = vec![
            0x13,
            0x37,
            if answer.is_some() { 0x81 } else { 0x01 },
            if answer.is_some() { 0x80 } else { 0 },
            0,
            1,
            0,
            u8::from(answer.is_some()),
            0,
            0,
            0,
            0,
        ];
        for label in domain.split('.') {
            wire.push(label.len() as u8);
            wire.extend_from_slice(label.as_bytes());
        }
        wire.extend_from_slice(&[0, 0, 1, 0, 1]);
        if let Some(ip) = answer {
            wire.extend_from_slice(&[0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4]);
            wire.extend_from_slice(&ip.octets());
        }
        wire
    }

    fn learned_tls_wire(domain: &str) -> Vec<u8> {
        let mut sni = Vec::new();
        sni.extend_from_slice(&((domain.len() + 3) as u16).to_be_bytes());
        sni.push(0);
        sni.extend_from_slice(&(domain.len() as u16).to_be_bytes());
        sni.extend_from_slice(domain.as_bytes());
        let mut hello = vec![3, 3];
        hello.extend_from_slice(&[0; 32]);
        hello.extend_from_slice(&[0, 0, 2, 0x13, 0x01, 1, 0]);
        hello.extend_from_slice(&((sni.len() + 4) as u16).to_be_bytes());
        hello.extend_from_slice(&[0, 0]);
        hello.extend_from_slice(&(sni.len() as u16).to_be_bytes());
        hello.extend_from_slice(&sni);
        let mut handshake = vec![1, 0];
        handshake.extend_from_slice(&(hello.len() as u16).to_be_bytes());
        handshake.extend_from_slice(&hello);
        let mut wire = vec![0x16, 3, 1];
        wire.extend_from_slice(&(handshake.len() as u16).to_be_bytes());
        wire.extend_from_slice(&handshake);
        wire
    }

    async fn assert_old_preresolve_rejected(stage: LearnedCheckpointStage, control: bool) {
        let fixture = learned_fixture().await;
        if control {
            fixture
                .relay
                .learned_test_hooks
                .set_resolutions(HashMap::new());
            fixture.update(LEARNED_A).await;
            fixture
                .relay
                .learned_test_hooks
                .set_resolutions(HashMap::from([
                    (LEARNED_A.to_owned(), vec!["93.184.216.34".parse().unwrap()]),
                    (LEARNED_B.to_owned(), vec!["1.1.1.1".parse().unwrap()]),
                ]));
        }
        let (reached, resume, done) = fixture
            .relay
            .learned_test_hooks
            .checkpoint(stage, LEARNED_A);
        if control {
            fixture.relay.preresolve_domains(vec![LEARNED_A.to_owned()]);
        } else {
            fixture
                .dispatcher
                .update_domain_routing(&format!("enabled=1;domains={LEARNED_A}"));
        }
        learned_notification(&reached).await;
        fixture.update(LEARNED_B).await;
        resume.notify_one();
        learned_notification(&done).await;
        let old_ip: IpAddr = "93.184.216.34".parse().unwrap();
        fixture.assert_udp_tunnels(old_ip).await;
        assert!(
            !fixture.relay.is_direct_ip(&old_ip),
            "old preregistration republished direct IP"
        );
        assert_eq!(
            fixture.relay.dns_domain_map.get(&old_ip),
            None,
            "old preregistration republished DNS map"
        );
        assert_eq!(
            fixture
                .relay
                .dns_domain_map
                .get(&"1.1.1.1".parse().unwrap())
                .as_deref(),
            Some(LEARNED_B)
        );
    }

    #[tokio::test]
    async fn learned_old_preresolve_before_map_commit_is_rejected() {
        assert_old_preresolve_rejected(LearnedCheckpointStage::PreresolveBeforeCommit, false).await;
    }

    #[tokio::test]
    async fn learned_old_preresolve_after_generation_check_is_rejected() {
        assert_old_preresolve_rejected(LearnedCheckpointStage::PreresolveAfterCheck, false).await;
    }

    #[tokio::test]
    async fn learned_control_preresolve_keeps_its_originating_rule() {
        assert_old_preresolve_rejected(LearnedCheckpointStage::PreresolveBeforeCommit, true).await;
    }

    async fn assert_intercepted_dns_reply_rejected(template_update: bool) {
        let mut fixture = learned_fixture().await;
        fixture
            .relay
            .learned_test_hooks
            .set_resolutions(HashMap::new());
        fixture.update(LEARNED_A).await;
        let upstream = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        *fixture.relay.learned_test_hooks.upstreams.lock().unwrap() =
            Some(vec![upstream.local_addr().unwrap()]);
        let query = learned_dns_wire(LEARNED_A, None);
        let raw = build_udp_packet(
            "198.51.100.12:53000".parse().unwrap(),
            "8.8.8.8:53".parse().unwrap(),
            &query,
        )
        .unwrap();
        let (reached, resume, done) = fixture
            .relay
            .learned_test_hooks
            .checkpoint(LearnedCheckpointStage::DnsReplyBeforeCommit, LEARNED_A);
        assert!(
            fixture
                .relay
                .try_handle(&learned_packet(&fixture.pool, &raw))
                .await
        );
        let mut received = [0u8; 512];
        let (len, client) =
            tokio::time::timeout(Duration::from_secs(2), upstream.recv_from(&mut received))
                .await
                .unwrap()
                .unwrap();
        assert_eq!(&received[..len], query);
        let answer_ip: Ipv4Addr = "93.184.216.34".parse().unwrap();
        upstream
            .send_to(&learned_dns_wire(LEARNED_A, Some(answer_ip)), client)
            .await
            .unwrap();
        learned_notification(&reached).await;
        if template_update {
            // Настоящая смена шаблона (пусто -> 10.0.0.0/8): очистка уже
            // пустого набора теперь no-op и не обязана инвалидировать epoch —
            // это ровно то, что проверяет отдельный тест повторов.
            let (sha, blob) = template_blob("10.0.0.0/8\n");
            fixture
                .dispatcher
                .update_template_ip_rules(&sha, Some(&blob))
                .unwrap();
        } else {
            fixture.update(LEARNED_B).await;
        }
        resume.notify_one();
        learned_notification(&done).await;
        let reply = tokio::time::timeout(Duration::from_secs(2), fixture.inbound.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            crate::sni::parse_ip_packet_dns(reply.as_slice()).unwrap(),
            (LEARNED_A.to_owned(), true, vec![IpAddr::V4(answer_ip)])
        );
        fixture.assert_udp_tunnels(IpAddr::V4(answer_ip)).await;
        assert!(!fixture.relay.is_direct_ip(&IpAddr::V4(answer_ip)));
        assert_eq!(
            fixture.relay.dns_domain_map.get(&IpAddr::V4(answer_ip)),
            None
        );

        // Новый ответ по той же production DNS-ветке остаётся полезным.
        let current_domain = if template_update {
            LEARNED_A
        } else {
            LEARNED_B
        };
        let query = learned_dns_wire(current_domain, None);
        let raw = build_udp_packet(
            "198.51.100.12:53001".parse().unwrap(),
            "8.8.8.8:53".parse().unwrap(),
            &query,
        )
        .unwrap();
        assert!(
            fixture
                .relay
                .try_handle(&learned_packet(&fixture.pool, &raw))
                .await
        );
        let (_, client) =
            tokio::time::timeout(Duration::from_secs(2), upstream.recv_from(&mut received))
                .await
                .unwrap()
                .unwrap();
        let current_ip: Ipv4Addr = "1.1.1.1".parse().unwrap();
        upstream
            .send_to(&learned_dns_wire(current_domain, Some(current_ip)), client)
            .await
            .unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(2), fixture.inbound.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            crate::sni::parse_ip_packet_dns(reply.as_slice()).unwrap().0,
            current_domain
        );
        assert!(fixture.relay.is_direct_ip(&IpAddr::V4(current_ip)));
        assert_eq!(
            fixture
                .relay
                .dns_domain_map
                .get(&IpAddr::V4(current_ip))
                .as_deref(),
            Some(current_domain)
        );
    }

    #[tokio::test]
    async fn learned_intercepted_dns_reply_is_rejected_but_still_delivered() {
        assert_intercepted_dns_reply_rejected(false).await;
    }

    #[tokio::test]
    async fn learned_template_update_shares_the_dns_publication_epoch() {
        assert_intercepted_dns_reply_rejected(true).await;
    }

    async fn assert_old_observation_rejected(tls: bool) {
        let fixture = learned_fixture().await;
        fixture
            .relay
            .learned_test_hooks
            .set_resolutions(HashMap::new());
        fixture.update(LEARNED_A).await;
        let old_ip: IpAddr = "93.184.216.34".parse().unwrap();
        let raw = if tls {
            build_tcp_packet(
                "10.66.67.2:52000".parse().unwrap(),
                SocketAddr::new(old_ip, 443),
                1,
                0,
                0x02,
                &learned_tls_wire(LEARNED_A),
            )
            .unwrap()
        } else {
            build_udp_packet(
                "8.8.8.8:53".parse().unwrap(),
                "10.66.67.2:52000".parse().unwrap(),
                &learned_dns_wire(LEARNED_A, Some("93.184.216.34".parse().unwrap())),
            )
            .unwrap()
        };
        if tls {
            assert_eq!(crate::sni::parse_ip_packet_sni(&raw).unwrap().0, LEARNED_A);
        } else {
            assert_eq!(crate::sni::parse_ip_packet_dns(&raw).unwrap().0, LEARNED_A);
        }
        let packet = learned_packet(&fixture.pool, &raw);
        let (reached_tx, reached_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        *fixture.relay.learned_test_hooks.observation.lock().unwrap() =
            Some((reached_tx, resume_rx));
        let dispatcher = fixture.dispatcher.clone();
        let observing =
            tokio::task::spawn_blocking(move || dispatcher.observe_routing_test_packet(&packet));
        reached_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        fixture.update(LEARNED_B).await;
        resume_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(2), observing)
            .await
            .unwrap()
            .unwrap();
        fixture.assert_udp_tunnels(old_ip).await;
        assert!(!fixture.relay.is_direct_ip(&old_ip));
        assert_eq!(fixture.relay.dns_domain_map.get(&old_ip), None);

        // Тот же наблюдатель с текущим origin не теряет валидную DNS/SNI связь.
        fixture
            .dispatcher
            .update_domain_routing(&format!("enabled=1;domains={LEARNED_A}"));
        fixture
            .dispatcher
            .observe_routing_test_packet(&learned_packet(&fixture.pool, &raw));
        assert!(fixture.relay.is_direct_ip(&old_ip));
        assert_eq!(
            fixture.relay.dns_domain_map.get(&old_ip).as_deref(),
            Some(LEARNED_A)
        );
    }

    #[tokio::test]
    async fn learned_plain_dns_observation_keeps_its_originating_rule() {
        assert_old_observation_rejected(false).await;
    }

    #[tokio::test]
    async fn learned_plain_sni_observation_keeps_its_originating_rule() {
        assert_old_observation_rejected(true).await;
    }

    #[tokio::test]
    async fn learned_udp_dns_reply_keeps_its_originating_rule_but_is_delivered() {
        let mut fixture = learned_fixture().await;
        fixture.update(LEARNED_A).await;
        *fixture.relay.learned_test_hooks.upstreams.lock().unwrap() =
            Some(vec![fixture.observer.local_addr().unwrap()]);
        let raw = build_udp_packet(
            "10.66.67.2:53000".parse().unwrap(),
            "93.184.216.34:53".parse().unwrap(),
            b"udp-request",
        )
        .unwrap();
        assert!(
            fixture
                .relay
                .try_handle(&learned_packet(&fixture.pool, &raw))
                .await
        );
        let mut received = [0u8; 512];
        let (_, client) = tokio::time::timeout(
            Duration::from_secs(2),
            fixture.observer.recv_from(&mut received),
        )
        .await
        .unwrap()
        .unwrap();
        let (reached, resume, done) = fixture
            .relay
            .learned_test_hooks
            .checkpoint(LearnedCheckpointStage::UdpReplyBeforeCommit, LEARNED_A);
        let learned_ip: Ipv4Addr = "93.184.216.35".parse().unwrap();
        fixture
            .observer
            .send_to(&learned_dns_wire(LEARNED_A, Some(learned_ip)), client)
            .await
            .unwrap();
        learned_notification(&reached).await;
        fixture.update(LEARNED_B).await;
        resume.notify_one();
        learned_notification(&done).await;
        let reply = tokio::time::timeout(Duration::from_secs(2), fixture.inbound.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            crate::sni::extract_dns_info(&reply.as_slice()[28..]).unwrap(),
            (LEARNED_A.to_owned(), true, vec![IpAddr::V4(learned_ip)])
        );
        fixture.assert_udp_tunnels(IpAddr::V4(learned_ip)).await;
        assert_eq!(
            fixture.relay.dns_domain_map.get(&IpAddr::V4(learned_ip)),
            None
        );
        assert!(!fixture.relay.is_direct_ip(&IpAddr::V4(learned_ip)));
        fixture
            .assert_udp_tunnels("93.184.216.34".parse().unwrap())
            .await;
    }

    #[tokio::test]
    async fn udp_flow_is_cached_after_the_first_packet() {
        let config = crate::dispatcher::DomainRoutingConfig {
            template_ip_rules: Arc::new(crate::sni::IpRuleSet::parse("93.184.216.34")),
            ..Default::default()
        };
        let (relay, pool) = test_relay_with_config(config);
        let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let dst: SocketAddr = "93.184.216.34:5000".parse().unwrap();
        let raw = build_udp_packet(src, dst, b"hello").unwrap();

        for _ in 0..2 {
            let mut packet = pool.try_acquire().unwrap();
            packet.extend_tail(raw.len()).unwrap().copy_from_slice(&raw);
            assert!(relay.try_handle(&packet).await);
        }
        assert_eq!(relay.udp_verdicts.read().unwrap().len(), 1);
    }

    /// Пятиминутная сверка присылает то же правило: живые прямые TCP-сессии,
    /// UDP-вердикты и UDP-сессии обязаны пережить повторную публикацию.
    /// Смена правила по-прежнему всё сбрасывает.
    #[tokio::test]
    async fn repeated_routing_sync_keeps_live_caches() {
        let config = crate::dispatcher::DomainRoutingConfig {
            enabled: true,
            template_ip_rules: Arc::new(crate::sni::IpRuleSet::parse("93.184.216.34")),
            ..Default::default()
        };
        let (relay, _pool) = test_relay_with_config(config.clone());
        let now = Instant::now();
        let udp_key = verdict_key(7);
        relay
            .udp_verdicts
            .write()
            .unwrap()
            .insert(udp_key, crate::sni::RouteVerdict::Direct, now);
        let tcp_key = (
            "10.66.67.2:5000".parse().unwrap(),
            "93.184.216.34:443".parse().unwrap(),
        );
        relay.active_tcp.write().unwrap().insert(tcp_key, now);
        let udp_source: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let socket = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
        relay
            .udp_sessions
            .write()
            .unwrap()
            .insert(udp_source, socket);

        relay.sync_domain_routing(&config);

        assert_eq!(
            relay.udp_verdicts.read().unwrap().get(&udp_key, now),
            Some(crate::sni::RouteVerdict::Direct),
            "повторная публикация не должна сбрасывать verdict-кеш"
        );
        assert!(
            relay.active_tcp.read().unwrap().contains_key(&tcp_key),
            "повторная публикация не должна рвать прямые TCP-сессии"
        );
        assert!(
            relay.udp_sessions.read().unwrap().contains_key(&udp_source),
            "повторная публикация не должна менять исходный UDP-порт"
        );

        let changed = crate::dispatcher::DomainRoutingConfig {
            enabled: false,
            ..config
        };
        relay.sync_domain_routing(&changed);

        assert!(
            relay
                .udp_verdicts
                .read()
                .unwrap()
                .get(&udp_key, now)
                .is_none(),
            "смена правила обязана сбросить verdict-кеш"
        );
        assert!(!relay.active_tcp.read().unwrap().contains_key(&tcp_key));
        assert!(!relay.udp_sessions.read().unwrap().contains_key(&udp_source));
    }

    fn udp_update_configs(
        domains: bool,
    ) -> (
        crate::dispatcher::DomainRoutingConfig,
        crate::dispatcher::DomainRoutingConfig,
    ) {
        if domains {
            (
                crate::dispatcher::DomainRoutingConfig {
                    enabled: true,
                    is_whitelist: true,
                    ..Default::default()
                },
                crate::dispatcher::DomainRoutingConfig {
                    enabled: true,
                    ..Default::default()
                },
            )
        } else {
            (
                crate::dispatcher::DomainRoutingConfig {
                    template_ip_rules: Arc::new(crate::sni::IpRuleSet::parse("93.184.216.34")),
                    ..Default::default()
                },
                crate::dispatcher::DomainRoutingConfig {
                    template_ip_rules: Arc::new(crate::sni::IpRuleSet::parse("1.1.1.1")),
                    ..Default::default()
                },
            )
        }
    }

    async fn assert_udp_update_race(domains: bool, stage: UdpRouteCheckpointStage, cached: bool) {
        let (old, updated) = udp_update_configs(domains);
        let (mut relay, pool) = test_relay_with_config(old);
        let observer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        relay.udp_test_target = Some(observer.local_addr().unwrap());
        let relay = Arc::new(relay);
        let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let dst: SocketAddr = "93.184.216.34:5000".parse().unwrap();
        let raw = build_udp_packet(src, dst, b"routing-race").unwrap();
        let mut packet = pool.try_acquire().unwrap();
        packet.extend_tail(raw.len()).unwrap().copy_from_slice(&raw);
        let mut received = [0u8; 32];
        if cached {
            assert!(relay.try_handle(&packet).await);
            tokio::time::timeout(Duration::from_secs(2), observer.recv_from(&mut received))
                .await
                .unwrap()
                .unwrap();
        }
        let reached = Arc::new(tokio::sync::Notify::new());
        let resume = Arc::new(tokio::sync::Notify::new());
        *relay.udp_route_checkpoint.lock().unwrap() = Some(UdpRouteCheckpoint {
            stage,
            reached: reached.clone(),
            resume: resume.clone(),
        });
        let handling_relay = relay.clone();
        let handling = tokio::spawn(async move { handling_relay.try_handle(&packet).await });
        tokio::time::timeout(Duration::from_secs(2), reached.notified())
            .await
            .unwrap();

        let updated = Arc::new(updated);
        if domains {
            relay.sync_domain_routing(&updated);
        } else {
            // UPDATE_IPS меняет только шаблон и не запускает пререзолв доменов.
            relay.invalidate_route_caches();
        }
        resume.notify_one();
        let handled = tokio::time::timeout(Duration::from_secs(2), handling)
            .await
            .unwrap()
            .unwrap();
        let sent =
            tokio::time::timeout(Duration::from_millis(50), observer.recv_from(&mut received))
                .await
                .is_ok();
        assert!(
            !sent,
            "stale Direct sent UDP: domains={domains}, stage={stage:?}, cached={cached}"
        );
        assert!(
            !handled,
            "stale Direct consumed the packet after a completed routing update"
        );
        assert_ne!(
            relay.udp_verdicts.read().unwrap().get(
                &VerdictKey {
                    src,
                    dst,
                    protocol: 17
                },
                Instant::now(),
            ),
            Some(crate::sni::RouteVerdict::Direct),
            "a stale Direct verdict was reinserted after invalidation"
        );
    }

    #[tokio::test]
    async fn udp_domain_update_after_snapshot_rejects_stale_direct() {
        assert_udp_update_race(true, UdpRouteCheckpointStage::Snapshot, false).await;
    }

    #[tokio::test]
    async fn udp_template_update_after_snapshot_rejects_stale_direct() {
        assert_udp_update_race(false, UdpRouteCheckpointStage::Snapshot, false).await;
    }

    #[tokio::test]
    async fn udp_domain_update_after_cached_verdict_rejects_stale_direct() {
        assert_udp_update_race(true, UdpRouteCheckpointStage::Verdict, true).await;
    }

    #[tokio::test]
    async fn udp_template_update_after_cached_verdict_rejects_stale_direct() {
        assert_udp_update_race(false, UdpRouteCheckpointStage::Verdict, true).await;
    }

    #[tokio::test]
    async fn udp_domain_update_before_send_rejects_stale_direct() {
        assert_udp_update_race(true, UdpRouteCheckpointStage::Send, false).await;
    }

    #[tokio::test]
    async fn udp_template_update_before_send_rejects_stale_direct() {
        assert_udp_update_race(false, UdpRouteCheckpointStage::Send, false).await;
    }

    #[tokio::test]
    async fn udp_new_snapshot_does_not_reuse_the_previous_configs_cached_direct() {
        for domains in [true, false] {
            let (old, updated) = udp_update_configs(domains);
            let (mut relay, pool) = test_relay_with_config(old);
            let observer = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
            relay.udp_test_target = Some(observer.local_addr().unwrap());
            let raw = build_udp_packet(
                "10.66.67.2:5000".parse().unwrap(),
                "93.184.216.34:5000".parse().unwrap(),
                b"snapshot",
            )
            .unwrap();
            let mut packet = pool.try_acquire().unwrap();
            packet.extend_tail(raw.len()).unwrap().copy_from_slice(&raw);
            assert!(relay.try_handle(&packet).await);
            let mut received = [0u8; 32];
            tokio::time::timeout(Duration::from_secs(2), observer.recv_from(&mut received))
                .await
                .unwrap()
                .unwrap();

            // Другой поток уже опубликовал snapshot, но ещё не очистил кеш.
            relay.domain_routing.store(Arc::new(updated));
            let handled = relay.try_handle(&packet).await;
            let sent =
                tokio::time::timeout(Duration::from_millis(50), observer.recv_from(&mut received))
                    .await
                    .is_ok();
            assert!(
                !sent,
                "a new snapshot used the old cached Direct: domains={domains}"
            );
            assert!(!handled);
        }
    }

    #[tokio::test]
    async fn tcp_syn_does_not_read_the_udp_cache() {
        let config = crate::dispatcher::DomainRoutingConfig {
            enabled: true,
            ..Default::default()
        };
        let (relay, pool) = test_relay_with_config(config);
        let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let dst: SocketAddr = "8.8.8.8:443".parse().unwrap();
        relay.udp_verdicts.write().unwrap().insert(
            VerdictKey {
                src,
                dst,
                protocol: 17,
            },
            crate::sni::RouteVerdict::Direct,
            Instant::now(),
        );
        let raw = build_tcp_packet(src, dst, 1, 0, 0x02, &[]).unwrap();
        let mut packet = pool.try_acquire().unwrap();
        packet.extend_tail(raw.len()).unwrap().copy_from_slice(&raw);
        assert!(!relay.try_handle(&packet).await);
    }

    #[tokio::test]
    async fn routing_config_change_clears_cached_verdicts() {
        let config = crate::dispatcher::DomainRoutingConfig {
            enabled: true,
            ..Default::default()
        };
        let (relay, _pool) = test_relay_with_config(config);
        let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let dst: SocketAddr = "8.8.8.8:443".parse().unwrap();
        relay
            .active_tcp
            .write()
            .unwrap()
            .insert((src, dst), Instant::now());
        relay.udp_verdicts.write().unwrap().insert(
            VerdictKey {
                src,
                dst,
                protocol: 17,
            },
            crate::sni::RouteVerdict::Direct,
            Instant::now(),
        );

        relay.sync_domain_routing(&crate::dispatcher::DomainRoutingConfig::default());

        assert!(relay.active_tcp.read().unwrap().is_empty());
        assert_eq!(relay.udp_verdicts.read().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn preresolve_uses_only_server_supplied_domains() {
        let supplied = vec![" 127.0.0.1 ".to_owned(), "127.0.0.1".to_owned()];
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                direct_domains: supplied.clone().into(),
                ..Default::default()
            },
        ));
        let direct_ips = Arc::new(ArcSwap::from_pointee(std::collections::HashSet::new()));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let origin = dns_domain_map.routing_origin(&domain_routing);

        run_full_preresolve_task(
            direct_ips.clone(),
            dns_domain_map.clone(),
            domain_routing,
            origin,
            supplied,
            Arc::new(LearnedTestHooks::default()),
        )
        .await;

        let expected: IpAddr = "127.0.0.1".parse().unwrap();
        assert_eq!(
            **direct_ips.load(),
            std::collections::HashSet::from([expected])
        );
        assert_eq!(dns_domain_map.get(&expected).as_deref(), Some("127.0.0.1"));
    }

    #[tokio::test]
    async fn disabled_domain_routing_does_not_use_preregistered_ips() {
        let config = crate::dispatcher::DomainRoutingConfig {
            direct_domains: vec!["custom.example".to_owned()].into(),
            ..Default::default()
        };
        let (relay, pool) = test_relay_with_config(config);
        let src: SocketAddr = "10.66.67.2:5000".parse().unwrap();
        let dst: SocketAddr = "93.184.216.34:5000".parse().unwrap();
        relay
            .direct_ips
            .store(Arc::new(std::collections::HashSet::from([dst.ip()])));
        let raw = build_udp_packet(src, dst, b"disabled").unwrap();
        let mut packet = pool.try_acquire().unwrap();
        packet.extend_tail(raw.len()).unwrap().copy_from_slice(&raw);

        assert!(!relay.try_handle(&packet).await);
        assert_eq!(relay.udp_verdicts.read().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn test_run_full_preresolve_task_preserves_dynamic_ips() {
        let domain_routing = Arc::new(ArcSwap::from_pointee(
            crate::dispatcher::DomainRoutingConfig {
                enabled: true,
                is_whitelist: false,
                direct_domains: vec![].into(),
                ip_is_whitelist: false,
                ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
                template_ip_rules: std::sync::Arc::new(crate::sni::IpRuleSet::default()),
            },
        ));
        let dynamic_ip: IpAddr = "123.45.67.89".parse().unwrap();
        let direct_ips = Arc::new(ArcSwap::from_pointee(
            std::iter::once(dynamic_ip).collect::<std::collections::HashSet<IpAddr>>(),
        ));
        let dns_domain_map = Arc::new(crate::sni::DnsDomainMap::default());
        let origin = dns_domain_map.routing_origin(&domain_routing);

        run_full_preresolve_task(
            direct_ips.clone(),
            dns_domain_map,
            domain_routing,
            origin,
            vec![],
            Arc::new(LearnedTestHooks::default()),
        )
        .await;

        let loaded = direct_ips.load();
        assert!(loaded.contains(&dynamic_ip));
    }
}
