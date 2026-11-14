#[cfg(test)]
use crate::turn_core::{AF_IPV4, NativeAddress};
use crate::{
    dns,
    packet::{PACKET_CAPACITY, PACKET_HEADROOM, PacketBuf, PacketPool},
    spsc_ring::{self, SpscReceiver, SpscSender, TrySendError},
    turn_core::{
        EVENT_CHANNEL_BOUND, EVENT_CHANNEL_REBIND_EXHAUSTED, EVENT_CONTROL_OVERFLOW,
        EVENT_EVENT_OVERFLOW, EVENT_FORCED_DESTROY, EVENT_RELAY_ADDRESS, EVENT_REQUEST_COMPLETE,
        EVENT_STATE, EVENT_STUN_RESPONSE_ERROR, METHOD_ALLOCATE, METHOD_CHANNEL_BIND,
        METHOD_CREATE_PERMISSION, METHOD_REFRESH, NativeCore, RESULT_AUTHENTICATION,
        RESULT_PROTOCOL, RESULT_TIMEOUT, STATE_DEALLOCATED, STATE_DESTROYING, STATE_READY,
        TurnControlTransport, native_status_text,
    },
    turn_endpoint::{TurnEndpoint, TurnTransportMode, TurnWireTransport, resolve_turn_endpoints},
    turn_stream::{
        self, TurnStreamFrame, TurnStreamReader, TurnStreamWriteFailure, TurnStreamWriter,
    },
};
use anyhow::{Context, Result, anyhow, bail};
use crossbeam_queue::ArrayQueue;
use socket2::SockRef;
use std::{
    net::SocketAddr,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    net::UdpSocket,
    sync::{Notify, OwnedSemaphorePermit, Semaphore, watch},
    task::JoinHandle,
};

const CONTROL_MAX: usize = 2048;
const MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xa4, 0x42];
/// Размер буфера приёма UDP-сокета TURN-канала (`SO_RCVBUF` на запросе).
///
/// Почему 128 КБ, а не 32 КБ. Замер на живом стенде после расширения кольца:
/// `queue_full_drops`/`pool_deficit_drops` обнулились, но сокет продолжал
/// терять — `RcvbufErrors=588`, и в 3 из 10 холодных стартов не доходило 2–7
/// чанков из 51. То есть дроп переехал на уровень ниже: пакет гибнет в
/// ядерном буфере сокета, ещё до нашего кольца, и ни `queue_full_drops`, ни
/// `pool_deficit_drops` этого не видят в принципе.
///
/// Арифметика бурста: доставка правила — это ≤ 137 пакетов (см.
/// `INCOMING_QUEUE_CAPACITY`), в поле обычно 51 чанк + START/FINISH ≈ 53
/// пакета. Ядро считает место не по полезным байтам, а по `skb->truesize` с
/// накладными: для датаграммы ~735 Б на проводе это от ~1.1 КБ (типично) до
/// 1.5–2 КБ в худшем случае, значит типичный бурст занимает ≈ 60–108 КБ.
/// Старые 32 КБ запроса после удвоения давали ≈ 64 КБ, и этого впритык: любой
/// media-трафик того же соединения вытесняет control-пакеты.
///
/// Что реально даёт запрос 128 КБ. Ядро удваивает запрошенное и режет по
/// `net.core.rmem_max`, поэтому выданное ≈ `min(256 КБ, rmem_max)` — см.
/// `ANDROID_RMEM_MAX_BYTES`. По памяти на устройство: 10 воркеров × ~208 КБ
/// ≈ 2.08 МБ ядра (считаем уже от потолка, а не от 2 × запроса). Просить 256 КБ
/// смысла нет: после удвоения и отсечения выдали бы те же ~208 КБ, только
/// явнее упёршись в потолок. Для сравнения: другие сокеты процесса просят
/// больше (`dispatcher.rs` — 1 МиБ, `direct_relay.rs` — 256 КиБ).
///
/// Операционный предел после ввода серверного pacing'а — НЕ вся доставка, а
/// один батч: сервер спит после каждых 16 строк
/// (`ROUTING_DELIVERY_BATCH` в `rust-server/protocol.rs`), так что в очередь
/// ядра одновременно ложится ≈ 18–33 КБ по truesize-оценке (16 × 1.1–2 КБ;
/// ~12 КБ в полезных байтах), а не 137 пакетов целиком.
///
/// Когда пересматривать: рост числа пакетов в одном батче (изменение pacing
/// или возврат дублирования чанков), рост числа воркеров, либо другой вендорский
/// потолок `rmem_max` на целевом устройстве. Максимальный легитимный бурст
/// (137 пакетов) целиком этим бюджетом покрывается только при
/// `truesize ≤ 1554 Б` — при 2 КБ он уже не влезает, и тогда единственная
/// защита — серверный pacing (батч 16 пакетов ≈ 18–33 КБ), а не размер буфера.
const UDP_RECEIVE_BUFFER_BYTES: usize = 128 * 1024;
/// Типичный потолок `net.core.rmem_max` на Android: то, сколько ядро
/// действительно выдаёт сокету, каким бы большим ни был удвоенный запрос.
/// ОРИЕНТИР, а не гарантия: значение задаёт вендорный образ, на некоторых
/// прошивках оно меньше (или его поднимают через `setprop`), поэтому тест
/// сверяется с `min(2 × запрос, этот потолок)`, а фактическое выданное надо
/// подтверждать read-back-логом `SO_RCVBUF`, а не считать аксиомой.
///
/// Живёт под `#[cfg(test)]`: в рантайме потолок не применяем сами — это решение
/// ядра, и единственное честное, что мы можем, — прочитать результат.
#[cfg(test)]
const ANDROID_RMEM_MAX_BYTES: usize = 208 * 1024;
const UDP_SEND_BUFFER_BYTES: usize = 16 * 1024;
const _: () = assert!(UDP_RECEIVE_BUFFER_BYTES + UDP_SEND_BUFFER_BYTES <= 512 * 1024);
/// Слотов во входящем SPSC-кольце: сюда ложатся ВСЕ расшифрованные ChannelData
/// соединения — и data-plane, и control-строки (`TUNCONF`, `ROUTING:…`).
/// При переполнении `process_packet` не применяет backpressure: пакет дропается
/// молча, только `queue_full_drops` растёт, поэтому ёмкость кольца — это окно на
/// один бурст, а не очередь на всю жизнь.
///
/// Почему 256, а не 16. Замер на живом стенде с диагностикой: холодная доставка
/// полного правила при 16 слотах теряла ~50 датаграмм из ~104 (`queue_drops=52`
/// на первом срабатывании watchdog, `pool_drops=0`), и дублирование чанков на
/// сервере не помогало — соседние копии гибнут в одном и том же окне
/// переполнения.
///
/// Верхняя граница легитимного бурста считается из лимита события, а не из
/// «примерно 65 КБ base64»: 65 536 ограничивает РАЗМЕР raw JSON правила
/// (`validate_routing_rule` режет `routing_event_line` на 65 536 Б,
/// `rust-server/protocol.rs`), а чанки везут `base64(gzip(raw_json))`. В худшем
/// (плохо сжимаемом) случае gzip ≈ raw, base64 — это ×4/3, дальше деление по
/// `chunk_size` и +2 пакета на `START`/`FINISH`. Каждый шаг берётся потолком:
/// `⌈65 536 × 4 / 3⌉ = 87 382` байт base64 → `⌈87 382 / 650⌉ = 135` чанков →
/// `135 + 2 = 137` пакетов. 256 покрывает это с запасом ~1.9×.
///
/// Запаса на дублирование чанков здесь НЕТ: удвоенный вариант того же бурста —
/// 2 × 135 + 2 = 272 пакета, что больше 256. Если дублирование когда-нибудь
/// вернут, ёмкость надо пересматривать сразу (нужно ≥272, по конвенции — 512),
/// иначе кольцо снова начнёт молча дропать ровно те пакеты, ради которых
/// дублирование и делалось.
///
/// По памяти безопасно: слоты берут буферы из общего пула
/// `packet_pool_size(MAX_WORKERS) = 6656`, так что 256 слота — это ≤ 256 × 2 КБ
/// уже учтённых буферов, новых аллокаций не появляется. Отдельно: после
/// подъёма кольца за `pool_drops` надо продолжать следить так же внимательно,
/// как за `queue_drops` (замер `pool_drops=0` был снят при 16 слотах) —
/// следующий молчаливый дроп будет называться именно так, потому что пул пакетов
/// общий на все соединения, а `PACKET_POOL_SHARED` тоже равен 256.
///
/// Пересматривать при росте доставки выше 137 пакетов — это
/// `⌈65 536 × 4/3⌉ ÷ 650 + 2`, формула закреплена за константой
/// `MAX_RULE_DELIVERY_PACKETS` в тесте
/// `turn_socket_buffer_budget_is_bounded_per_worker`, а не выбрана на глаз.
const INCOMING_QUEUE_CAPACITY: usize = 256;
const CONTROL_TIMEOUT: Duration = Duration::from_secs(12);
const ALLOCATION_TIMEOUT: Duration = Duration::from_secs(25);
const TRANSPORT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(35);
const READY_CLEANUP_TIMEOUT: Duration = Duration::from_secs(12);
const CLEANUP_ERROR_RETRY: Duration = Duration::from_millis(100);
const MAX_BACKGROUND_CLEANUPS: usize = 128;
const UDP_TRANSIENT_ERROR_LIMIT: u32 = 16;
const UDP_TRANSIENT_ERROR_WINDOW: Duration = Duration::from_secs(5);
const OUTBOUND_QUEUE_CAPACITY: usize = 8;
const OUTBOUND_IDLE_POLL: Duration = Duration::from_millis(20);
const OUTBOUND_FLUSH_WAIT: Duration = Duration::from_millis(250);

#[inline]
fn is_retryable_maintenance(method: u32) -> bool {
    matches!(
        method,
        METHOD_CREATE_PERMISSION | METHOD_CHANNEL_BIND | METHOD_REFRESH
    )
}

#[inline]
fn is_silent_native_status(status: i32) -> bool {
    matches!(
        status,
        RESULT_TIMEOUT | RESULT_AUTHENTICATION | RESULT_PROTOCOL
    )
}

#[derive(Debug)]
pub struct TurnRequestError {
    method: u32,
    status: i32,
    stun_code: i32,
}

impl TurnRequestError {
    pub(crate) fn new(method: u32, status: i32, stun_code: i32) -> Self {
        Self {
            method,
            status,
            stun_code,
        }
    }

    pub fn stun_code(&self) -> i32 {
        self.stun_code
    }
}

impl std::fmt::Display for TurnRequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "TURN {} failed: {}{}",
            method_name(self.method),
            native_status_text(self.status),
            stun_suffix(self.stun_code)
        )
    }
}

impl std::error::Error for TurnRequestError {}

#[derive(Clone, Default)]
struct Completion {
    sequence: u64,
    status: i32,
    stun_code: i32,
}

#[derive(Clone, Default)]
struct CoreSnapshot {
    state: u32,
    relay: Option<SocketAddr>,
    channel: Option<u16>,
    allocate: Completion,
    refresh: Completion,
    permission: Completion,
    channel_bind: Completion,
    terminal: Option<Arc<str>>,
}

impl CoreSnapshot {
    fn completion(&self, method: u32) -> &Completion {
        match method {
            METHOD_ALLOCATE => &self.allocate,
            METHOD_REFRESH => &self.refresh,
            METHOD_CREATE_PERMISSION => &self.permission,
            METHOD_CHANNEL_BIND => &self.channel_bind,
            _ => &self.allocate,
        }
    }

    fn completion_mut(&mut self, method: u32) -> Option<&mut Completion> {
        match method {
            METHOD_ALLOCATE => Some(&mut self.allocate),
            METHOD_REFRESH => Some(&mut self.refresh),
            METHOD_CREATE_PERMISSION => Some(&mut self.permission),
            METHOD_CHANNEL_BIND => Some(&mut self.channel_bind),
            _ => None,
        }
    }
}

struct DriverShared {
    snapshot: watch::Sender<CoreSnapshot>,
    wake: Notify,
    closing: AtomicBool,
    terminal_present: AtomicBool,
    control_sent: AtomicBool,
    channel: AtomicU16,
    queue_full_drops: AtomicU64,
    outbound_queue_full_drops: AtomicU64,
    pool_deficit_drops: AtomicU64,
    #[cfg(test)]
    native_pumps: AtomicU64,
}

impl DriverShared {
    fn fail(&self, reason: impl Into<Arc<str>>) {
        if self.closing.load(Ordering::Acquire) {
            return;
        }
        let reason = reason.into();
        let mut inserted = false;
        self.snapshot.send_modify(|snapshot| {
            if snapshot.terminal.is_none() {
                snapshot.terminal = Some(reason.clone());
                inserted = true;
            }
        });
        if inserted {
            self.terminal_present.store(true, Ordering::Release);
            self.wake.notify_waiters();
        }
    }

    fn terminal(&self) -> Option<Arc<str>> {
        self.terminal_present
            .load(Ordering::Acquire)
            .then(|| self.snapshot.borrow().terminal.clone())
            .flatten()
    }

    fn request_cleanup(&self) {
        self.closing.store(true, Ordering::Release);
        self.channel.store(0, Ordering::Release);
        self.wake.notify_one();
    }
}

pub struct TurnAllocation {
    outbound: TurnOutbound,
    core: Arc<NativeCore>,
    incoming: Mutex<Option<SpscReceiver<PacketBuf>>>,
    shared: Arc<DriverShared>,
    relay_address: Mutex<SocketAddr>,
    prepare_lock: tokio::sync::Mutex<()>,
    driver: Mutex<Option<JoinHandle<()>>>,
    outbound_queue: Option<Arc<OutboundQueue>>,
    outbound_writer: Mutex<Option<JoinHandle<()>>>,
    deallocated: AtomicBool,
}

pub struct TurnConnectTarget<'a> {
    pub address: &'a str,
    pub override_host: Option<&'a str>,
    pub override_port: Option<&'a str>,
    pub transport_mode: TurnTransportMode,
}

#[derive(Clone)]
enum TurnOutbound {
    Udp(Arc<UdpSocket>),
    Stream(Arc<TurnStreamWriter>),
}

struct OutboundQueue {
    queue: ArrayQueue<PacketBuf>,
    waiter: Notify,
    space: Notify,
    /// Packets popped from `queue` but not yet handed to the socket. The queue
    /// being empty is not enough for `deallocate`: between `pop()` and
    /// `try_send()` the queue is empty while the packet is still on its way.
    in_flight: AtomicUsize,
    shared: Arc<DriverShared>,
    socket: Arc<UdpSocket>,
}

/// Marks one packet as in flight; dropping it wakes a waiting `deallocate`.
/// Acquired *before* the pop: otherwise a packet popped between the emptiness
/// check and the counter bump would be sent after the deallocate refresh.
struct InFlightGuard<'a>(&'a OutboundQueue);

impl<'a> InFlightGuard<'a> {
    fn acquire(queue: &'a OutboundQueue) -> Self {
        queue.in_flight.fetch_add(1, Ordering::AcqRel);
        Self(queue)
    }
}

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        if self.0.in_flight.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.0.space.notify_one();
        }
    }
}

async fn outbound_writer_loop(queue: Arc<OutboundQueue>) {
    loop {
        loop {
            let in_flight = InFlightGuard::acquire(&queue);
            let Some(mut packet) = queue.queue.pop() else {
                drop(in_flight);
                break;
            };
            queue.space.notify_one();
            if queue.shared.closing.load(Ordering::Acquire) {
                drop(packet);
                continue;
            }
            let channel = queue.shared.channel.load(Ordering::Acquire);
            if channel == 0 || encode_channel_data(&mut packet, channel).is_err() {
                queue
                    .shared
                    .outbound_queue_full_drops
                    .fetch_add(1, Ordering::Relaxed);
                drop(packet);
                continue;
            }
            match queue.socket.try_send(packet.as_slice()) {
                Ok(_) => {}
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // Backpressure: ждём, пока send-буфер сокета освободится,
                    // вместо тихого сброса при переполнении.
                    while !queue.shared.closing.load(Ordering::Acquire) {
                        if queue.socket.writable().await.is_err() {
                            queue
                                .shared
                                .outbound_queue_full_drops
                                .fetch_add(1, Ordering::Relaxed);
                            break;
                        }
                        match queue.socket.try_send(packet.as_slice()) {
                            Ok(_) => break,
                            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                tokio::time::sleep(Duration::from_micros(50)).await;
                            }
                            Err(_) => {
                                queue
                                    .shared
                                    .outbound_queue_full_drops
                                    .fetch_add(1, Ordering::Relaxed);
                                break;
                            }
                        }
                    }
                }
                Err(_) => {
                    queue
                        .shared
                        .outbound_queue_full_drops
                        .fetch_add(1, Ordering::Relaxed);
                }
            }
            drop(packet);
        }
        if queue.shared.closing.load(Ordering::Acquire) {
            return;
        }
        // Ждём только реального пробуждения: `notify_one` ставится и при
        // отправке, и при `deallocate`, поэтому периодический поллинг не нужен.
        queue.waiter.notified().await;
    }
}

enum TurnInbound {
    Udp(Arc<UdpSocket>),
    Stream(TurnStreamReader, TurnStreamWriteFailure),
}

pub struct TurnReceiver {
    incoming: SpscReceiver<PacketBuf>,
    state: watch::Receiver<CoreSnapshot>,
    shared: Arc<DriverShared>,
}

impl TurnReceiver {
    pub async fn recv(&mut self) -> Result<PacketBuf> {
        loop {
            if let Some(reason) = self.shared.terminal() {
                bail!("{reason}");
            }
            if let Some(packet) = self.incoming.try_recv() {
                return Ok(packet);
            }
            let notified = self.incoming.notifier().notified_owned();
            tokio::pin!(notified);
            if self.incoming.rearm_notification() {
                continue;
            }
            if let Some(packet) = self.incoming.try_recv() {
                return Ok(packet);
            }
            tokio::select! {
                biased;
                changed = self.state.changed() => {
                    if changed.is_err() {
                        bail!("TURN allocation state closed");
                    }
                }
                _ = &mut notified => {}
            }
        }
    }

    /// Сколько входящих `ChannelData` было выброшено из-за нехватки пакета в
    /// пуле (`process_deficit_packet` для UDP и `TurnStreamFrame::DataDropped`
    /// для потока): приёмник такой пакет не буферизует, а отдаёт
    /// `PacketAction::Wait` — то есть датаграмма просто исчезает.
    ///
    /// Счётчик накопительный за всю жизнь аллокации: это снимок «сколько дропов
    /// случилось к текущему моменту», а не число потерь в конкретной доставке.
    ///
    /// Нужен только для диагностики: у `TurnAllocation` такие же геттеры
    /// помечены `#[cfg(test)]`, то есть в рабочем процессе их не было вовсе.
    pub fn ingress_pool_deficit_drops(&self) -> u64 {
        self.shared.pool_deficit_drops.load(Ordering::Relaxed)
    }

    /// Сколько пакетов было выброшено из-за переполнения входящей SPSC-очереди
    /// (`try_send` вернул `TrySendError::Full`) — тоже накопительно за жизнь
    /// аллокации.
    pub fn ingress_queue_full_drops(&self) -> u64 {
        self.shared.queue_full_drops.load(Ordering::Relaxed)
    }
}

impl TurnAllocation {
    pub async fn connect(
        target: TurnConnectTarget<'_>,
        username: Arc<str>,
        password: Arc<str>,
        peer: SocketAddr,
        pool: Arc<PacketPool>,
    ) -> Result<Arc<Self>> {
        if username.len() > 512 {
            bail!("TURN username превышает 512 байт");
        }
        if password.len() > 512 {
            bail!("TURN password превышает 512 байт");
        }
        let endpoints = resolve_turn_endpoints(
            target.address,
            target.override_host,
            target.override_port,
            target.transport_mode,
        )?;
        let (outbound, inbound, server, transport) = connect_transport(&endpoints).await?;
        crate::log_error!("[TURN] Транспорт: {}", transport.as_str());
        let control_transport = if transport == TurnWireTransport::Udp {
            TurnControlTransport::Datagram
        } else {
            TurnControlTransport::Stream
        };
        let core = NativeCore::create_with_transport(
            server,
            &username,
            &password,
            peer,
            control_transport,
        )?;
        let (snapshot, _) = watch::channel(CoreSnapshot::default());
        let shared = Arc::new(DriverShared {
            snapshot,
            wake: Notify::new(),
            closing: AtomicBool::new(false),
            terminal_present: AtomicBool::new(false),
            control_sent: AtomicBool::new(false),
            channel: AtomicU16::new(0),
            queue_full_drops: AtomicU64::new(0),
            outbound_queue_full_drops: AtomicU64::new(0),
            pool_deficit_drops: AtomicU64::new(0),
            #[cfg(test)]
            native_pumps: AtomicU64::new(0),
        });
        let (incoming_tx, incoming_rx) = spsc_ring::channel(INCOMING_QUEUE_CAPACITY);
        let driver = tokio::spawn(driver_loop(DriverRuntime {
            outbound: outbound.clone(),
            inbound,
            core: core.clone(),
            pool: pool.clone(),
            incoming: incoming_tx,
            shared: shared.clone(),
            server,
            peer,
        }));
        let (outbound_queue, outbound_writer) = match &outbound {
            TurnOutbound::Udp(socket) => {
                let queue = Arc::new(OutboundQueue {
                    queue: ArrayQueue::new(OUTBOUND_QUEUE_CAPACITY),
                    waiter: Notify::new(),
                    space: Notify::new(),
                    in_flight: AtomicUsize::new(0),
                    shared: shared.clone(),
                    socket: socket.clone(),
                });
                let writer_task = tokio::spawn(outbound_writer_loop(queue.clone()));
                (Some(queue), Some(writer_task))
            }
            TurnOutbound::Stream(_) => (None, None),
        };
        let allocation = Arc::new(Self {
            outbound,
            core,
            incoming: Mutex::new(Some(incoming_rx)),
            shared,
            relay_address: Mutex::new(SocketAddr::new(server.ip(), 0)),
            prepare_lock: tokio::sync::Mutex::new(()),
            driver: Mutex::new(Some(driver)),
            outbound_queue,
            outbound_writer: Mutex::new(outbound_writer),
            deallocated: AtomicBool::new(false),
        });
        let baseline = allocation.completion_sequence(METHOD_ALLOCATE);
        if let Err(error) = allocation.core.start_allocation() {
            allocation.shared.fail(Arc::from(format!("{error:#}")));
            return Err(error);
        }
        allocation.shared.wake.notify_one();
        let relay_address = match tokio::time::timeout(
            ALLOCATION_TIMEOUT,
            allocation.wait_for_allocation(baseline),
        )
        .await
        {
            Ok(result) => result?,
            Err(_) => {
                allocation
                    .shared
                    .fail("TURN Allocate exceeded the hard safety deadline");
                bail!("TURN Allocate exceeded the hard safety deadline");
            }
        };
        *allocation
            .relay_address
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = relay_address;
        crate::log_error!("[TURN] Аллокация активна: relay {relay_address}");
        Ok(allocation)
    }

    pub fn local_addr(&self) -> SocketAddr {
        *self
            .relay_address
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn take_receiver(&self) -> Result<TurnReceiver> {
        let incoming = self
            .incoming
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
            .context("TURN receiver already acquired")?;
        Ok(TurnReceiver {
            incoming,
            state: self.shared.snapshot.subscribe(),
            shared: self.shared.clone(),
        })
    }

    pub async fn prepare_channel(&self) -> Result<()> {
        let _guard = self.prepare_lock.lock().await;
        self.ensure_open()?;
        if self.shared.channel.load(Ordering::Acquire) != 0 {
            return Ok(());
        }
        self.bind_channel(true).await
    }

    async fn bind_channel(&self, log_ready: bool) -> Result<()> {
        let channel_baseline = self.completion_sequence(METHOD_CHANNEL_BIND);
        if let Err(error) = self.core.start_permission() {
            self.shared.fail(Arc::from(format!("{error:#}")));
            return Err(error);
        }
        if let Err(error) = self.core.start_channel() {
            self.shared.fail(Arc::from(format!("{error:#}")));
            return Err(error);
        }
        self.shared.wake.notify_one();
        self.wait_for_completion(METHOD_CHANNEL_BIND, channel_baseline, CONTROL_TIMEOUT)
            .await?;
        let mut receiver = self.shared.snapshot.subscribe();
        tokio::time::timeout(CONTROL_TIMEOUT, async {
            loop {
                let snapshot = receiver.borrow().clone();
                if let Some(reason) = snapshot.terminal {
                    bail!("{reason}");
                }
                if snapshot.channel.is_some() {
                    return Ok(());
                }
                receiver
                    .changed()
                    .await
                    .context("TURN ChannelBind state channel closed")?;
            }
        })
        .await
        .context("TURN ChannelBind confirmation timeout")??;
        if log_ready {
            crate::log_error!("[TURN] Сессия готова к передаче данных ✓");
        }
        Ok(())
    }

    pub fn is_alive(&self) -> bool {
        !self.deallocated.load(Ordering::Acquire)
            && self.shared.terminal().is_none()
            && self.shared.channel.load(Ordering::Acquire) != 0
    }

    pub fn is_sendable(&self) -> bool {
        if !self.is_alive() {
            return false;
        }
        match &self.outbound {
            TurnOutbound::Udp(_) => self
                .outbound_queue
                .as_ref()
                .is_some_and(|queue| !queue.queue.is_full()),
            TurnOutbound::Stream(writer) => writer.can_send(),
        }
    }

    pub fn try_send_fast(&self, packet: PacketBuf) -> Option<PacketBuf> {
        let queue = match (&self.outbound_queue, &self.outbound) {
            (Some(queue), TurnOutbound::Udp(_)) => queue,
            _ => return Some(packet),
        };
        if self.deallocated.load(Ordering::Acquire)
            || self.shared.terminal().is_some()
            || self.shared.channel.load(Ordering::Acquire) == 0
        {
            return Some(packet);
        }
        let mut packet = packet;
        match queue.queue.push(packet) {
            Ok(()) => {
                queue.waiter.notify_one();
                None
            }
            Err(returned) => {
                packet = returned;
                Some(packet)
            }
        }
    }

    pub async fn send(&self, mut packet: PacketBuf) -> Result<()> {
        self.ensure_open()?;
        let channel = self.shared.channel.load(Ordering::Acquire);
        if channel == 0 {
            bail!("TURN ChannelBind обязателен");
        }
        match &self.outbound {
            TurnOutbound::Udp(_) => {
                let queue = self
                    .outbound_queue
                    .as_ref()
                    .context("TURN UDP outbound queue missing")?;
                let mut packet = packet;
                loop {
                    match queue.queue.push(packet) {
                        Ok(()) => {
                            queue.waiter.notify_one();
                            return Ok(());
                        }
                        Err(returned) => {
                            packet = returned;
                        }
                    }
                    // Backpressure вместо тихого сброса: ждём место в очереди
                    // воркера, пока аллокация жива. Пакет сбрасывается только
                    // когда аллокация закрывается или деаллоцируется.
                    if self.deallocated.load(Ordering::Acquire)
                        || self.shared.closing.load(Ordering::Acquire)
                        || self.shared.terminal().is_some()
                    {
                        return Ok(());
                    }
                    let space = queue.space.notified();
                    match queue.queue.push(packet) {
                        Ok(()) => {
                            queue.waiter.notify_one();
                            return Ok(());
                        }
                        Err(returned) => {
                            packet = returned;
                        }
                    }
                    let _ = tokio::time::timeout(OUTBOUND_IDLE_POLL, space).await;
                }
            }
            TurnOutbound::Stream(writer) => {
                encode_channel_data(&mut packet, channel)?;
                writer.write_data(packet)?;
                Ok(())
            }
        }
    }

    pub async fn deallocate(&self) {
        if self.deallocated.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Some(queue) = &self.outbound_queue {
            queue.waiter.notify_one();
            let flush_deadline = Instant::now() + OUTBOUND_FLUSH_WAIT;
            while (!queue.queue.is_empty() || queue.in_flight.load(Ordering::Acquire) > 0)
                && Instant::now() < flush_deadline
            {
                let remaining = flush_deadline.saturating_duration_since(Instant::now());
                let space = queue.space.notified();
                if queue.queue.is_empty() && queue.in_flight.load(Ordering::Acquire) == 0 {
                    break;
                }
                let _ = tokio::time::timeout(remaining, space).await;
            }
        }
        self.shared.request_cleanup();
        if let Some(queue) = &self.outbound_queue {
            queue.waiter.notify_one();
        }
        let outbound_writer = self
            .outbound_writer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(mut outbound_writer) = outbound_writer
            && tokio::time::timeout(Duration::from_secs(1), &mut outbound_writer)
                .await
                .is_err()
        {
            outbound_writer.abort();
            let _ = outbound_writer.await;
        }
        let _ = self.core.graceful_shutdown();
        let driver = self
            .driver
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(mut driver) = driver
            && tokio::time::timeout(CLEANUP_TIMEOUT + Duration::from_secs(1), &mut driver)
                .await
                .is_err()
        {
            self.core.force_destroy(0);
            driver.abort();
            let _ = driver.await;
        }
    }

    fn ensure_open(&self) -> Result<()> {
        if self.shared.closing.load(Ordering::Acquire) {
            bail!("TURN allocation closing");
        }
        if let Some(reason) = self.shared.terminal() {
            bail!("{reason}");
        }
        Ok(())
    }

    fn completion_sequence(&self, method: u32) -> u64 {
        self.shared.snapshot.borrow().completion(method).sequence
    }

    async fn wait_for_allocation(&self, baseline: u64) -> Result<SocketAddr> {
        self.wait_for_completion(METHOD_ALLOCATE, baseline, ALLOCATION_TIMEOUT)
            .await?;
        let mut receiver = self.shared.snapshot.subscribe();
        loop {
            let snapshot = receiver.borrow().clone();
            if let Some(reason) = snapshot.terminal {
                bail!("{reason}");
            }
            if snapshot.state == STATE_READY
                && let Some(relay) = snapshot.relay
            {
                return Ok(relay);
            }
            receiver
                .changed()
                .await
                .context("TURN Allocate state channel closed")?;
        }
    }

    async fn wait_for_completion(
        &self,
        method: u32,
        baseline: u64,
        timeout: Duration,
    ) -> Result<()> {
        let mut receiver = self.shared.snapshot.subscribe();
        tokio::time::timeout(timeout, async {
            loop {
                let snapshot = receiver.borrow().clone();
                let completion = snapshot.completion(method);
                if completion.sequence > baseline {
                    if completion.status == 0 && completion.stun_code == 0 {
                        return Ok(());
                    }
                    return Err(anyhow::Error::new(TurnRequestError::new(
                        method,
                        completion.status,
                        completion.stun_code,
                    )));
                }
                if let Some(reason) = snapshot.terminal {
                    bail!("{reason}");
                }
                receiver.changed().await.with_context(|| {
                    format!("TURN {} state channel closed", method_name(method))
                })?;
            }
        })
        .await
        .with_context(|| format!("TURN {} hard timeout", method_name(method)))?
    }

    #[cfg(test)]
    pub fn ingress_queue_full_drops(&self) -> u64 {
        self.shared.queue_full_drops.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub fn ingress_pool_deficit_drops(&self) -> u64 {
        self.shared.pool_deficit_drops.load(Ordering::Relaxed)
    }

    #[cfg(all(test, unix))]
    pub fn outbound_queue_full_drops(&self) -> u64 {
        self.shared
            .outbound_queue_full_drops
            .load(Ordering::Relaxed)
    }

    #[cfg(test)]
    fn native_pump_count(&self) -> u64 {
        self.shared.native_pumps.load(Ordering::Relaxed)
    }
}

impl Drop for TurnAllocation {
    fn drop(&mut self) {
        self.shared.request_cleanup();
        if let Some(queue) = &self.outbound_queue {
            queue.waiter.notify_one();
        }
        let _ = self.core.graceful_shutdown();
        let _ = self
            .driver
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
    }
}

async fn connect_transport(
    endpoints: &[TurnEndpoint],
) -> Result<(TurnOutbound, TurnInbound, SocketAddr, TurnWireTransport)> {
    let mut failures = Vec::with_capacity(endpoints.len());
    for endpoint in endpoints {
        let authority = endpoint.socket_authority();
        let attempt = match tokio::time::timeout(TRANSPORT_CONNECT_TIMEOUT, async {
            let server = dns::resolve_socket(&authority).await?;
            match endpoint.transport {
                TurnWireTransport::Udp => {
                    let bind = if server.is_ipv4() {
                        SocketAddr::from(([0, 0, 0, 0], 0))
                    } else {
                        SocketAddr::from(([0u16; 8], 0))
                    };
                    let socket = Arc::new(UdpSocket::bind(bind).await.context("TURN UDP bind")?);
                    configure_udp_socket_buffers(&socket);
                    socket
                        .connect(server)
                        .await
                        .with_context(|| format!("TURN UDP connect {server}"))?;
                    Ok((
                        TurnOutbound::Udp(socket.clone()),
                        TurnInbound::Udp(socket),
                        server,
                        TurnWireTransport::Udp,
                    ))
                }
                TurnWireTransport::Tcp | TurnWireTransport::Tls => {
                    let (writer, reader, write_failure) =
                        turn_stream::connect(endpoint, server).await?;
                    Ok((
                        TurnOutbound::Stream(writer),
                        TurnInbound::Stream(reader, write_failure),
                        server,
                        endpoint.transport,
                    ))
                }
            }
        })
        .await
        {
            Ok(result) => result,
            Err(_) => Err(anyhow!(
                "TURN {} transport setup timed out after {} seconds",
                endpoint.transport.as_str(),
                TRANSPORT_CONNECT_TIMEOUT.as_secs()
            )),
        };
        match attempt {
            Ok(value) => return Ok(value),
            Err(error) => failures.push(format!("{}: {error:#}", endpoint.transport.as_str())),
        }
    }
    bail!(
        "TURN transport endpoints are unavailable: {}",
        failures.join(" | ")
    )
}

struct DriverRuntime {
    outbound: TurnOutbound,
    inbound: TurnInbound,
    core: Arc<NativeCore>,
    pool: Arc<PacketPool>,
    incoming: SpscSender<PacketBuf>,
    shared: Arc<DriverShared>,
    server: SocketAddr,
    peer: SocketAddr,
}

struct DriverCommon {
    outbound: TurnOutbound,
    core: Arc<NativeCore>,
    pool: Arc<PacketPool>,
    incoming: SpscSender<PacketBuf>,
    shared: Arc<DriverShared>,
    server: SocketAddr,
    peer: SocketAddr,
}

async fn driver_loop(runtime: DriverRuntime) {
    let DriverRuntime {
        outbound,
        inbound,
        core,
        pool,
        incoming,
        shared,
        server,
        peer,
    } = runtime;
    let common = DriverCommon {
        outbound,
        core,
        pool,
        incoming,
        shared,
        server,
        peer,
    };
    match inbound {
        TurnInbound::Udp(socket) => driver_loop_udp(common, socket).await,
        TurnInbound::Stream(reader, write_failure) => {
            driver_loop_stream(common, reader, write_failure).await
        }
    }
}

#[derive(Default)]
struct UdpReceiveErrors {
    count: u32,
    first: Option<Instant>,
}

impl UdpReceiveErrors {
    fn tolerate(&mut self, error: &std::io::Error) -> bool {
        if !matches!(
            error.kind(),
            std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::ConnectionReset
        ) {
            return false;
        }
        let now = Instant::now();
        let first = *self.first.get_or_insert(now);
        self.count += 1;
        if self.count == 1 {
            eprintln!("TURN UDP transient receive error, retrying: {error}");
        }
        self.count <= UDP_TRANSIENT_ERROR_LIMIT
            && now.duration_since(first) <= UDP_TRANSIENT_ERROR_WINDOW
    }

    fn clear(&mut self) {
        self.count = 0;
        self.first = None;
    }
}

async fn driver_loop_udp(common: DriverCommon, socket: Arc<UdpSocket>) {
    let DriverCommon {
        outbound,
        core,
        pool,
        mut incoming,
        shared,
        server,
        peer,
    } = common;
    let mut deficit_buffer = [0u8; PACKET_CAPACITY - PACKET_HEADROOM];
    let mut cleanup_deadline = None;
    let mut cleanup_permit: Option<OwnedSemaphorePermit> = None;
    let mut shutdown_requested = false;
    let mut native_deadline = Instant::now();
    let mut pump_needed = true;
    let mut receive_errors = UdpReceiveErrors::default();
    loop {
        if shared.closing.load(Ordering::Acquire) {
            if !shared.control_sent.load(Ordering::Acquire) {
                break;
            }
            if cleanup_permit.is_none() {
                cleanup_permit = match cleanup_limiter().clone().try_acquire_owned() {
                    Ok(permit) => Some(permit),
                    Err(_) => break,
                };
            }
            let state = shared.snapshot.borrow().state;
            let (deadline, started) =
                start_driver_cleanup(&core, &mut cleanup_deadline, &mut shutdown_requested, state);
            pump_needed |= started;
            if state >= STATE_DEALLOCATED || Instant::now() >= deadline {
                break;
            }
        }
        let now = Instant::now();
        if pump_needed || now >= native_deadline {
            match pump_native(&outbound, &core, &shared, server, peer).await {
                Ok(delay) => {
                    native_deadline =
                        Instant::now() + delay.unwrap_or(Duration::from_secs(24 * 60 * 60));
                    pump_needed = false;
                    continue;
                }
                Err(error) => {
                    shared.fail(Arc::from(format!("{error:#}")));
                    shared.request_cleanup();
                    if !shared.control_sent.load(Ordering::Acquire) {
                        break;
                    }
                    if let Some(deadline) = cleanup_deadline {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            break;
                        }
                        tokio::time::sleep(CLEANUP_ERROR_RETRY.min(remaining)).await;
                    }
                    pump_needed = true;
                    continue;
                }
            }
        }
        let wait_deadline =
            cleanup_deadline.map_or(native_deadline, |deadline| deadline.min(native_deadline));
        let mut wait = wait_deadline.saturating_duration_since(Instant::now());
        if wait.is_zero() {
            wait = Duration::from_millis(1);
        }
        if shared.closing.load(Ordering::Acquire) {
            while let Ok(length) = socket.try_recv(&mut deficit_buffer) {
                if matches!(
                    process_deficit_packet(&core, &shared, &deficit_buffer[..length]),
                    PacketAction::Pump
                ) {
                    pump_needed = true;
                }
            }
            let event = tokio::select! {
                biased;
                _ = shared.wake.notified() => DriverEvent::Wake,
                _ = tokio::time::sleep(wait) => DriverEvent::Timer,
                result = socket.recv(&mut deficit_buffer) => DriverEvent::Packet(result),
            };
            match event {
                DriverEvent::Wake | DriverEvent::Timer => {
                    pump_needed = true;
                }
                DriverEvent::Packet(Ok(length)) => {
                    receive_errors.clear();
                    pump_needed = matches!(
                        process_deficit_packet(&core, &shared, &deficit_buffer[..length]),
                        PacketAction::Pump
                    );
                }
                DriverEvent::Packet(Err(error)) => {
                    if !receive_errors.tolerate(&error) {
                        shared.fail(Arc::from(format!("TURN UDP receive failed: {error}")));
                    }
                    pump_needed = true;
                    tokio::time::sleep(CLEANUP_ERROR_RETRY).await;
                }
                DriverEvent::Readable(_) => {}
            }
        } else {
            let mut burst_count = 0usize;
            while burst_count < 32 {
                let (received, would_block) = match pool.try_acquire() {
                    Some(mut packet) => match socket.try_recv(packet.read_area()) {
                        Ok(length) => {
                            receive_errors.clear();
                            let pump = if packet.set_read_len(length).is_ok() {
                                matches!(
                                    process_packet(&core, &shared, &mut incoming, packet),
                                    PacketAction::Pump
                                )
                            } else {
                                false
                            };
                            (pump, false)
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            (false, true)
                        }
                        Err(error) => {
                            if receive_errors.tolerate(&error) {
                                (false, false)
                            } else {
                                shared.fail(Arc::from(format!("TURN UDP receive failed: {error}")));
                                shared.request_cleanup();
                                pump_needed = true;
                                break;
                            }
                        }
                    },
                    None => match socket.try_recv(&mut deficit_buffer) {
                        Ok(length) => {
                            receive_errors.clear();
                            (
                                matches!(
                                    process_deficit_packet(
                                        &core,
                                        &shared,
                                        &deficit_buffer[..length]
                                    ),
                                    PacketAction::Pump
                                ),
                                false,
                            )
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            (false, true)
                        }
                        Err(error) => {
                            if receive_errors.tolerate(&error) {
                                (false, false)
                            } else {
                                shared.fail(Arc::from(format!("TURN UDP receive failed: {error}")));
                                shared.request_cleanup();
                                pump_needed = true;
                                break;
                            }
                        }
                    },
                };
                pump_needed |= received;
                if would_block {
                    break;
                }
                burst_count += 1;
            }
            if pump_needed {
                continue;
            }
            let event = tokio::select! {
                biased;
                _ = shared.wake.notified() => DriverEvent::Wake,
                _ = tokio::time::sleep(wait) => DriverEvent::Timer,
                result = socket.readable() => DriverEvent::Readable(result),
            };
            match event {
                DriverEvent::Wake | DriverEvent::Timer => {
                    pump_needed = true;
                }
                DriverEvent::Readable(Ok(())) => {}
                DriverEvent::Readable(Err(error)) => {
                    shared.fail(Arc::from(format!("TURN UDP readiness failed: {error}")));
                    shared.request_cleanup();
                    pump_needed = true;
                }
                DriverEvent::Packet(_) => {}
            }
        }
    }
    core.force_destroy(0);
}

async fn driver_loop_stream(
    common: DriverCommon,
    mut reader: TurnStreamReader,
    mut write_failure: TurnStreamWriteFailure,
) {
    let DriverCommon {
        outbound,
        core,
        pool,
        mut incoming,
        shared,
        server,
        peer,
    } = common;
    let mut cleanup_deadline = None;
    let mut cleanup_permit: Option<OwnedSemaphorePermit> = None;
    let mut shutdown_requested = false;
    let mut native_deadline = Instant::now();
    let mut pump_needed = true;
    loop {
        if shared.closing.load(Ordering::Acquire) {
            if !shared.control_sent.load(Ordering::Acquire) {
                break;
            }
            if cleanup_permit.is_none() {
                cleanup_permit = match cleanup_limiter().clone().try_acquire_owned() {
                    Ok(permit) => Some(permit),
                    Err(_) => break,
                };
            }
            let state = shared.snapshot.borrow().state;
            let (deadline, started) =
                start_driver_cleanup(&core, &mut cleanup_deadline, &mut shutdown_requested, state);
            pump_needed |= started;
            if state >= STATE_DEALLOCATED || Instant::now() >= deadline {
                break;
            }
        }
        let now = Instant::now();
        if pump_needed || now >= native_deadline {
            match pump_native(&outbound, &core, &shared, server, peer).await {
                Ok(delay) => {
                    native_deadline =
                        Instant::now() + delay.unwrap_or(Duration::from_secs(24 * 60 * 60));
                    pump_needed = false;
                    continue;
                }
                Err(error) => {
                    shared.fail(Arc::from(format!("{error:#}")));
                    shared.request_cleanup();
                    if !shared.control_sent.load(Ordering::Acquire) {
                        break;
                    }
                    if let Some(deadline) = cleanup_deadline {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            break;
                        }
                        tokio::time::sleep(CLEANUP_ERROR_RETRY.min(remaining)).await;
                    }
                    pump_needed = true;
                    continue;
                }
            }
        }
        let wait_deadline =
            cleanup_deadline.map_or(native_deadline, |deadline| deadline.min(native_deadline));
        let mut wait = wait_deadline.saturating_duration_since(Instant::now());
        if wait.is_zero() {
            wait = Duration::from_millis(1);
        }
        let event = tokio::select! {
            biased;
            _ = shared.wake.notified() => StreamDriverEvent::Wake,
            _ = tokio::time::sleep(wait) => StreamDriverEvent::Timer,
            changed = write_failure.changed() => StreamDriverEvent::WriteFailure(changed),
            result = reader.read_frame(&pool) => StreamDriverEvent::Frame(result),
        };
        match event {
            StreamDriverEvent::Wake | StreamDriverEvent::Timer => {
                pump_needed = true;
            }
            StreamDriverEvent::WriteFailure(Ok(())) => {
                if let Some(reason) = write_failure.borrow().clone()
                    && !shared.closing.load(Ordering::Acquire)
                {
                    shared.fail(Arc::from(format!("TURN stream transmit failed: {reason}")));
                    shared.request_cleanup();
                    pump_needed = true;
                }
            }
            StreamDriverEvent::WriteFailure(Err(_)) => break,
            StreamDriverEvent::Frame(Ok(TurnStreamFrame::Control(frame))) => {
                if matches!(
                    process_deficit_packet(&core, &shared, &frame),
                    PacketAction::Pump
                ) {
                    pump_needed = true;
                }
            }
            StreamDriverEvent::Frame(Ok(TurnStreamFrame::Data(packet))) => {
                match process_packet(&core, &shared, &mut incoming, packet) {
                    PacketAction::Wait => {}
                    PacketAction::Pump => pump_needed = true,
                }
            }
            StreamDriverEvent::Frame(Ok(TurnStreamFrame::DataDropped)) => {
                shared.pool_deficit_drops.fetch_add(1, Ordering::Relaxed);
            }
            StreamDriverEvent::Frame(Err(error)) => {
                if !shared.closing.load(Ordering::Acquire) {
                    shared.fail(Arc::from(format!("TURN stream receive failed: {error:#}")));
                }
                shared.request_cleanup();
                break;
            }
        }
    }
    core.force_destroy(0);
}

enum DriverEvent {
    Wake,
    Timer,
    Packet(std::io::Result<usize>),
    Readable(std::io::Result<()>),
}

enum StreamDriverEvent {
    Wake,
    Timer,
    WriteFailure(Result<(), tokio::sync::watch::error::RecvError>),
    Frame(Result<TurnStreamFrame>),
}

fn start_driver_cleanup(
    core: &NativeCore,
    cleanup_deadline: &mut Option<Instant>,
    shutdown_requested: &mut bool,
    state: u32,
) -> (Instant, bool) {
    let now = Instant::now();
    let timeout = if state >= STATE_READY {
        READY_CLEANUP_TIMEOUT
    } else {
        CLEANUP_TIMEOUT
    };
    let proposed_deadline = now + timeout;
    let deadline = cleanup_deadline.get_or_insert(proposed_deadline);
    if proposed_deadline < *deadline {
        *deadline = proposed_deadline;
    }
    let mut started = false;
    if !*shutdown_requested {
        *shutdown_requested = true;
        started = true;
        let _ = core.graceful_shutdown();
    }
    (*deadline, started)
}

fn cleanup_limiter() -> &'static Arc<Semaphore> {
    static LIMITER: OnceLock<Arc<Semaphore>> = OnceLock::new();
    LIMITER.get_or_init(|| Arc::new(Semaphore::new(MAX_BACKGROUND_CLEANUPS)))
}

async fn pump_native(
    outbound: &TurnOutbound,
    core: &NativeCore,
    shared: &DriverShared,
    server: SocketAddr,
    peer: SocketAddr,
) -> Result<Option<Duration>> {
    #[cfg(test)]
    shared.native_pumps.fetch_add(1, Ordering::Relaxed);
    let next_timer = core.poll()?;
    let mut control = [0u8; CONTROL_MAX];
    while let Some((length, destination)) = core.pull_control(&mut control)? {
        if destination != server {
            bail!("TURN core attempted control send to unexpected destination {destination}");
        }
        match outbound {
            TurnOutbound::Udp(socket) => {
                socket
                    .send(&control[..length])
                    .await
                    .context("TURN control UDP send")?;
            }
            TurnOutbound::Stream(writer) => writer.write_control(&control[..length]).await?,
        }
        shared.control_sent.store(true, Ordering::Release);
    }
    let mut unexpected_destroy = false;
    let mut channel_rebind_exhausted = false;
    let mut last_stun_error: Option<(u32, i32)> = None;
    while let Some(event) = core.pull_event()? {
        match event.kind {
            EVENT_STATE => {
                if event.state != STATE_READY {
                    shared.channel.store(0, Ordering::Release);
                }
                shared.snapshot.send_modify(|snapshot| {
                    snapshot.state = event.state;
                    if event.state != STATE_READY {
                        snapshot.channel = None;
                    }
                    if event.state >= STATE_DEALLOCATED {
                        snapshot.relay = None;
                    }
                });
                if event.state == STATE_DESTROYING && !shared.closing.load(Ordering::Acquire) {
                    unexpected_destroy = true;
                }
            }
            EVENT_REQUEST_COMPLETE => {
                shared.snapshot.send_modify(|snapshot| {
                    if let Some(completion) = snapshot.completion_mut(event.method) {
                        completion.sequence = completion.sequence.wrapping_add(1);
                        completion.status = event.status;
                        completion.stun_code = event.stun_code;
                    }
                });
                if event.status == 0 && event.stun_code == 0 {
                    match event.method {
                        METHOD_CHANNEL_BIND => {
                            let channel = event.channel;
                            crate::log_error!("[TURN] ChannelBind активен: канал 0x{channel:04X}");
                        }
                        METHOD_REFRESH => {
                            crate::log_error!("[TURN] Refresh аллокации подтверждён ✓");
                        }
                        _ => {}
                    }
                }
                if (event.status != 0 || event.stun_code != 0)
                    && event.stun_code == 0
                    && !shared.closing.load(Ordering::Acquire)
                    && !is_silent_native_status(event.status)
                {
                    crate::log_error!(
                        "[TURN][ERROR] {}: {}",
                        method_name(event.method),
                        native_status_text(event.status)
                    );
                }
                if (event.status != 0 || event.stun_code != 0)
                    && !shared.closing.load(Ordering::Acquire)
                    && !is_retryable_maintenance(event.method)
                {
                    shared.fail(Arc::from(format!(
                        "TURN {} failed: {}{}",
                        method_name(event.method),
                        native_status_text(event.status),
                        stun_suffix(event.stun_code)
                    )));
                }
            }
            EVENT_STUN_RESPONSE_ERROR => {
                if event.stun_code != 0 {
                    last_stun_error = Some((event.method, event.stun_code));
                }
                if !shared.closing.load(Ordering::Acquire) && !is_silent_native_status(event.status)
                {
                    if event.stun_code != 0 {
                        if event.status == 0 {
                            crate::log_error!(
                                "[TURN][STUN] {}: STUN error {}",
                                method_name(event.method),
                                event.stun_code,
                            );
                        } else {
                            crate::log_error!(
                                "[TURN][STUN] {}: unverified STUN error {} after {}",
                                method_name(event.method),
                                event.stun_code,
                                native_status_text(event.status),
                            );
                        }
                    } else {
                        crate::log_error!(
                            "[TURN][STUN] {}: {}",
                            method_name(event.method),
                            native_status_text(event.status),
                        );
                    }
                }
            }
            EVENT_CHANNEL_BOUND => {
                let event_peer = event.address.to_socket_addr()?;
                if event_peer != peer {
                    shared.fail(Arc::from(format!(
                        "TURN ChannelBind confirmed unexpected peer {event_peer}"
                    )));
                } else if !(0x4000..=0x7fff).contains(&event.channel) {
                    shared.fail(Arc::from(format!(
                        "TURN core returned invalid channel {}",
                        event.channel
                    )));
                } else {
                    shared.channel.store(event.channel, Ordering::Release);
                    shared.snapshot.send_modify(|snapshot| {
                        snapshot.channel = Some(event.channel);
                    });
                }
            }
            EVENT_RELAY_ADDRESS => {
                let relay = event.address.to_socket_addr()?;
                let queried = core.relay_address()?;
                if queried != relay {
                    bail!("TURN core relay address event/getter mismatch");
                }
                shared.snapshot.send_modify(|snapshot| {
                    snapshot.relay = Some(relay);
                });
            }
            EVENT_CONTROL_OVERFLOW => {
                shared.fail(Arc::from(format!(
                    "TURN control output ring overflow dropped {} datagrams",
                    event.dropped
                )));
            }
            EVENT_FORCED_DESTROY => {
                if !shared.closing.load(Ordering::Acquire) {
                    shared.fail("TURN core was force-destroyed");
                }
            }
            EVENT_CHANNEL_REBIND_EXHAUSTED => {
                channel_rebind_exhausted = true;
            }
            EVENT_EVENT_OVERFLOW => {
                shared.fail(Arc::from(format!(
                    "TURN event ring overflow dropped {} events",
                    event.dropped
                )));
            }
            kind => {
                shared.fail(Arc::from(format!(
                    "TURN core returned unknown event {kind}"
                )));
            }
        }
    }
    if unexpected_destroy && shared.terminal().is_none() {
        if channel_rebind_exhausted {
            shared.fail("TURN channel rebind retry exhausted");
        } else if let Some((method, code)) = last_stun_error {
            shared.fail(Arc::from(format!(
                "TURN {} failed: STUN error {code}",
                method_name(method)
            )));
        } else {
            shared.fail("TURN allocation entered DESTROYING unexpectedly");
        }
    }
    Ok(next_timer)
}

fn process_packet(
    core: &NativeCore,
    shared: &DriverShared,
    incoming: &mut SpscSender<PacketBuf>,
    mut packet: PacketBuf,
) -> PacketAction {
    let wire = packet.as_slice();
    if let Some((channel, payload_length)) = channel_data_header(wire) {
        if channel != shared.channel.load(Ordering::Acquire) {
            return PacketAction::Wait;
        }
        if packet.trim_front(4).is_err() || packet.truncate(payload_length).is_err() {
            return PacketAction::Wait;
        }
        match incoming.try_send(packet) {
            Ok(()) => PacketAction::Wait,
            Err(TrySendError::Full(_)) => {
                shared.queue_full_drops.fetch_add(1, Ordering::Relaxed);
                PacketAction::Wait
            }
        }
    } else {
        if is_stun(wire) {
            let _ = core.input_stun(wire);
            return PacketAction::Pump;
        }
        PacketAction::Wait
    }
}

fn process_deficit_packet(core: &NativeCore, shared: &DriverShared, wire: &[u8]) -> PacketAction {
    if let Some((channel, _)) = channel_data_header(wire) {
        if channel == shared.channel.load(Ordering::Acquire) {
            shared.pool_deficit_drops.fetch_add(1, Ordering::Relaxed);
        }
        PacketAction::Wait
    } else if is_stun(wire) {
        let _ = core.input_stun(wire);
        PacketAction::Pump
    } else {
        PacketAction::Wait
    }
}

enum PacketAction {
    Wait,
    Pump,
}

fn channel_data_header(wire: &[u8]) -> Option<(u16, usize)> {
    if wire.len() < 4 || wire[0] & 0xc0 != 0x40 {
        return None;
    }
    let channel = u16::from_be_bytes([wire[0], wire[1]]);
    if !(0x4000..=0x7fff).contains(&channel) {
        return None;
    }
    let payload_length = u16::from_be_bytes([wire[2], wire[3]]) as usize;
    if payload_length > wire.len() - 4 {
        return None;
    }
    if wire.len() - 4 - payload_length > 3 {
        return None;
    }
    Some((channel, payload_length))
}

fn is_stun(wire: &[u8]) -> bool {
    wire.len() >= 20 && wire[0] & 0xc0 == 0 && wire[4..8] == MAGIC_COOKIE
}

fn encode_channel_data(packet: &mut PacketBuf, channel: u16) -> Result<()> {
    let padding = channel_data_padding(packet, channel)?;
    let payload_length = packet.len();
    packet.extend_tail(padding)?.fill(0);
    let header = packet.prepend(4)?;
    header[..2].copy_from_slice(&channel.to_be_bytes());
    header[2..4].copy_from_slice(&(payload_length as u16).to_be_bytes());
    Ok(())
}

fn channel_data_padding(packet: &PacketBuf, channel: u16) -> Result<usize> {
    if !(0x4000..=0x7fff).contains(&channel) {
        bail!("TURN channel is invalid");
    }
    let payload_length = packet.len();
    if payload_length > u16::MAX as usize {
        bail!("TURN payload too large");
    }
    let padding = (4 - payload_length % 4) % 4;
    let range = packet.range();
    if range.start < 4
        || range
            .end
            .checked_add(padding)
            .is_none_or(|end| end > PACKET_CAPACITY)
    {
        bail!("TURN ChannelData exceeds packet buffer");
    }
    Ok(padding)
}

fn configure_udp_socket_buffers(socket: &UdpSocket) {
    let socket = SockRef::from(socket);
    // Read-back обязателен: без него следующий замер `RcvbufErrors` не отличит
    // «ядро не применило запрос» (маленький `rmem_max`, права, другой вендорный
    // профиль) от «применило, но выданных байт не хватает на бурст». Ни один из
    // этих случаев не виден в `queue_full_drops`/`pool_deficit_drops` — они
    // считают дропы ниже сокета.
    //
    // Ошибку не считаем фатальной: сокет продолжает работать с унаследованным
    // буфером, и падать из-за diagnostics на боевом пути нельзя.
    let requested = UDP_RECEIVE_BUFFER_BYTES;
    if socket.set_recv_buffer_size(requested).is_err() {
        crate::log_error!("[TURN] SO_RCVBUF: запрос {requested} не принят ядром");
    }
    match socket.recv_buffer_size() {
        Ok(granted) => {
            crate::log_error!("[TURN] SO_RCVBUF: запрошено {requested}, выдано {granted}");
        }
        Err(error) => {
            crate::log_error!(
                "[TURN] SO_RCVBUF: запрошено {requested}, выданное не прочитать: {error}"
            );
        }
    }
    let _ = socket.set_send_buffer_size(UDP_SEND_BUFFER_BYTES);
}

fn method_name(method: u32) -> &'static str {
    match method {
        METHOD_ALLOCATE => "Allocate",
        METHOD_REFRESH => "Refresh",
        METHOD_CREATE_PERMISSION => "CreatePermission",
        METHOD_CHANNEL_BIND => "ChannelBind",
        _ => "request",
    }
}

fn stun_suffix(stun_code: i32) -> String {
    if stun_code == 0 {
        String::new()
    } else {
        format!("; STUN error {stun_code}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::turn_core::RESULT_INVALID_ARGUMENT;

    /// Сколько слотов кольцо принимает до отказа — фактическое поведение
    /// `spsc_ring`, а не заявленное число: классическая схема SPSC держит один
    /// слот пустым, чтобы различать full и empty, поэтому usable == запрошенная
    /// ёмкость.
    fn measured_incoming_ring_capacity() -> usize {
        let (mut tx, mut rx) = spsc_ring::channel::<u8>(INCOMING_QUEUE_CAPACITY);
        let mut accepted = 0usize;
        while tx.try_send(7).is_ok() {
            accepted += 1;
        }
        while rx.try_recv().is_some() {}
        assert!(
            tx.try_send(9).is_ok(),
            "после опорожнения кольцо снова принимает"
        );
        accepted
    }

    // Предел строки события с правилом: `validate_routing_rule` режет
    // `routing_event_line` по 65 536 Б (`rust-server/protocol.rs`). Граница
    // заведомо завышена: 65 536 — это ВСЯ строка события с обёрткой
    // `__CSQTT_EVENT__|ROUTING|{"routing": …}`, так что raw JSON чуть меньше.
    const ROUTING_EVENT_LIMIT_BYTES: usize = 65_536;
    // На сколько байтов сервер режет `base64(gzip(raw_json))` доставки правила.
    const ROUTING_CHUNK_BYTES: usize = 650;
    /// Максимальный легитимный ОДНОКРАТНЫЙ бурст доставки: в худшем (плохо
    /// сжимаемом) случае gzip ≈ raw (deflate на не сжимаемом входе добавляет
    /// доли процента, в пределах одного чанка), base64 домножает на 4/3,
    /// дальше делим по `chunk_size` и прибавляем `START` + `FINISH`.
    /// Каждый шаг — потолок, поэтому 137 именно верхняя граница:
    /// `⌈65 536 × 4 / 3⌉ = 87 382` → `⌈87 382 ÷ 650⌉ = 135` чанков → `+2 = 137`
    /// пакетов.
    const MAX_RULE_DELIVERY_BASE64_BYTES: usize = (ROUTING_EVENT_LIMIT_BYTES * 4).div_ceil(3);
    const MAX_RULE_DELIVERY_PACKETS: usize =
        MAX_RULE_DELIVERY_BASE64_BYTES.div_ceil(ROUTING_CHUNK_BYTES) + 2;

    /// Типичный бурст доставки на стенде: 51 чанк + `START` + `FINISH`.
    const TYPICAL_RULE_DELIVERY_PACKETS: usize = 53;
    /// Сколько пакетов успевает налиться в очередь между двумя серверными
    /// паузами — операционный предел после pacing'а. Зеркало
    /// `ROUTING_DELIVERY_BATCH` из `rust-server/protocol.rs`: при его изменении
    /// надо править и это число (и формулировку в комментарии к
    /// `UDP_RECEIVE_BUFFER_BYTES`).
    const ROUTING_DELIVERY_BATCH_PACKETS: usize = 16;

    #[test]
    fn turn_socket_buffer_budget_is_bounded_per_worker() {
        // 128 КБ: ядро удваивает запрос и режет по `net.core.rmem_max`, поэтому
        // СРАВНИВАЕМ НЕ с 2 × запросом, а с тем бюджетом, который реально может
        // быть выдан: min(256 КБ, 208 КБ). Иначе тест проверял бы бюджет,
        // которого не существует, и оставался бы зелёным при любой огромной
        // константе. Обоснование — в комментарии к UDP_RECEIVE_BUFFER_BYTES.
        assert_eq!(UDP_RECEIVE_BUFFER_BYTES, 128 * 1024);
        assert_eq!(UDP_SEND_BUFFER_BYTES, 16 * 1024);
        let effective_receive_budget_bytes =
            (2 * UDP_RECEIVE_BUFFER_BYTES).min(ANDROID_RMEM_MAX_BYTES);

        // Типичный бурст по ТИПИЧНОЙ оценке truesize (~1.1 КБ на датаграмму).
        let typical_truesize_bytes = 1127usize;
        let typical_burst_bytes = TYPICAL_RULE_DELIVERY_PACKETS * typical_truesize_bytes;
        assert!(
            typical_burst_bytes <= effective_receive_budget_bytes,
            "типичный бурст обязан помещаться в выданный SO_RCVBUF: \
             {typical_burst_bytes} > {effective_receive_budget_bytes}"
        );

        // Тот же типичный бурст по ВЕРХНЕЙ оценке truesize (1.5–2 КБ на
        // датаграмму ~735 Б на проводе). Именно этот случай и ловит
        // `RcvbufErrors=588`, поэтому проверяем по нему, а не по 1.1 КБ.
        let upper_truesize_bytes = 2048usize;
        let typical_burst_upper_bytes = TYPICAL_RULE_DELIVERY_PACKETS * upper_truesize_bytes;
        assert!(
            typical_burst_upper_bytes <= effective_receive_budget_bytes,
            "бурст даже по верхней оценке truesize обязан влезать в SO_RCVBUF: \
             {typical_burst_upper_bytes} > {effective_receive_budget_bytes}"
        );

        // Операционный предел — один батч pacing'а, а не вся доставка: 16
        // пакетов даже по верхней оценке это 32 КБ против бюджета 208 КБ.
        let batch_upper_bytes = ROUTING_DELIVERY_BATCH_PACKETS * upper_truesize_bytes;
        assert!(
            batch_upper_bytes <= effective_receive_budget_bytes,
            "батч между паузами обязан помещаться с многократным запасом: \
             {batch_upper_bytes} > {effective_receive_budget_bytes}"
        );

        // Честная граница того, чем этот бюджет прикрыт и чем нет: максимальный
        // легитимный бурст (137 пакетов) влезает в него при типичном truesize
        // (137 × 1127 = 154 399 ≤ 212 992), но НЕ влезает при верхней оценке
        // (137 × 2048 = 280 576 > 212 992). То есть для худшего случая на
        // максимальном бурсте защита одна — серверный pacing (батч 16 пакетов),
        // а не размер буфера; проверяем положительную половину этого утверждения.
        let max_burst_typical_bytes = MAX_RULE_DELIVERY_PACKETS * typical_truesize_bytes;
        assert!(
            max_burst_typical_bytes <= effective_receive_budget_bytes,
            "максимальный бурст по типичному truesize обязан влезать в SO_RCVBUF: \
             {max_burst_typical_bytes} > {effective_receive_budget_bytes}"
        );
        // Ёмкость входящего кольца — не магическое число, а окно на бурст
        // доставки правила. Порог ВЫЧИСЛЕН из лимита события (137 пакетов,
        // см. MAX_RULE_DELIVERY_PACKETS), а не выбран круглым: при 16 слотах
        // доставка полного правила терялась молча в `process_packet` (замер:
        // ~50 дропов на холодный старт, `queue_drops=52`, `pool_drops=0`).
        // Заодно 256 < 2 × 135 + 2 = 272, то есть запаса на возврат
        // дублирования чанков здесь нет — он отмечен в комментарии к константе.
        // Сверяем фактическую ёмкость кольца, а не константу: `assert!` на
        // константе clippy считает пустым.
        assert!(
            measured_incoming_ring_capacity() >= MAX_RULE_DELIVERY_PACKETS,
            "кольцо обязано вмещать максимальный легитимный бурст доставки \
             ({MAX_RULE_DELIVERY_PACKETS} пакетов), иначе чанки теряются до рессемблера"
        );
        // Sanity: закрепляем и сам расчёт — если константы лимита события или
        // `chunk_size` поедут, порог должен измениться явно, а не молча.
        assert_eq!(MAX_RULE_DELIVERY_PACKETS, 137);
    }

    #[test]
    fn transient_udp_receive_errors_are_bounded_until_a_receive_succeeds() {
        let refused = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        let mut errors = UdpReceiveErrors::default();
        for _ in 0..UDP_TRANSIENT_ERROR_LIMIT {
            assert!(errors.tolerate(&refused));
        }
        assert!(!errors.tolerate(&refused));
        errors.clear();
        assert!(errors.tolerate(&refused));
        assert!(!errors.tolerate(&std::io::Error::from(std::io::ErrorKind::Other)));
    }

    #[test]
    fn native_transport_failures_are_silent_in_the_user_log() {
        assert!(is_silent_native_status(RESULT_TIMEOUT));
        assert!(is_silent_native_status(RESULT_AUTHENTICATION));
        assert!(is_silent_native_status(RESULT_PROTOCOL));
        assert!(!is_silent_native_status(RESULT_INVALID_ARGUMENT));
        assert!(!is_silent_native_status(0));
    }

    #[test]
    fn channel_header_accepts_padding_and_rejects_truncation() {
        assert_eq!(
            channel_data_header(&[0x40, 0x21, 0, 3, 1, 2, 3, 0]),
            Some((0x4021, 3))
        );
        assert_eq!(channel_data_header(&[0x40, 0x21, 0, 4, 1, 2, 3]), None);
        assert_eq!(
            channel_data_header(&[0x40, 0x21, 0, 1, 1, 0, 0, 0, 0]),
            None
        );
        assert_eq!(channel_data_header(&[0x3f, 0xff, 0, 0]), None);
        assert_eq!(channel_data_header(&[0x80, 0, 0, 0]), None);
    }

    #[test]
    fn channel_encoding_reuses_storage_and_zeroes_padding() {
        let pool = PacketPool::new(1);
        let mut packet = pool.acquire();
        let storage = packet.storage_mut().as_ptr();
        packet.read_area()[..3].copy_from_slice(&[1, 2, 3]);
        packet.set_read_len(3).unwrap();
        encode_channel_data(&mut packet, 0x4567).unwrap();
        assert_eq!(packet.storage_mut().as_ptr(), storage);
        assert_eq!(packet.as_slice(), &[0x45, 0x67, 0, 3, 1, 2, 3, 0]);
    }

    #[test]
    fn stun_classifier_is_strict() {
        let mut packet = [0u8; 20];
        packet[4..8].copy_from_slice(&MAGIC_COOKIE);
        assert!(is_stun(&packet));
        packet[0] = 0x40;
        assert!(!is_stun(&packet));
        packet[0] = 0;
        packet[4] ^= 1;
        assert!(!is_stun(&packet));
    }

    #[test]
    fn native_addresses_are_host_endian_and_family_exact() {
        let mut address = NativeAddress {
            family: AF_IPV4,
            port: 3478,
            ..NativeAddress::default()
        };
        address.ip[..4].copy_from_slice(&[127, 0, 0, 1]);
        assert_eq!(
            address.to_socket_addr().unwrap(),
            SocketAddr::from(([127, 0, 0, 1], 3478))
        );
        address.family = 99;
        assert!(address.to_socket_addr().is_err());
    }

    #[test]
    fn invalid_channel_cannot_touch_packet() {
        let pool = PacketPool::new(1);
        let mut packet = pool.acquire();
        packet.read_area()[0] = 7;
        packet.set_read_len(1).unwrap();
        let before = packet.range();
        assert!(encode_channel_data(&mut packet, 0x3fff).is_err());
        assert_eq!(packet.range(), before);
        assert_eq!(packet.as_slice(), &[7]);
    }

    #[test]
    fn completion_sequences_are_independent() {
        let mut snapshot = CoreSnapshot::default();
        snapshot.completion_mut(METHOD_ALLOCATE).unwrap().sequence = 1;
        snapshot
            .completion_mut(METHOD_CHANNEL_BIND)
            .unwrap()
            .sequence = 2;
        snapshot.completion_mut(METHOD_REFRESH).unwrap().sequence = 3;
        snapshot
            .completion_mut(METHOD_CREATE_PERMISSION)
            .unwrap()
            .sequence = 4;
        assert_eq!(snapshot.completion(METHOD_ALLOCATE).sequence, 1);
        assert_eq!(snapshot.completion(METHOD_CHANNEL_BIND).sequence, 2);
        assert_eq!(snapshot.completion(METHOD_REFRESH).sequence, 3);
        assert_eq!(snapshot.completion(METHOD_CREATE_PERMISSION).sequence, 4);
    }

    #[test]
    fn native_core_is_thread_safe_by_contract() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<NativeCore>();
    }
}

#[cfg(test)]
#[path = "turn_integration_tests.rs"]
mod integration_tests;
