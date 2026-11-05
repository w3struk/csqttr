use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::sync::RwLock;
use std::time::Instant;

pub fn extract_tls_sni(payload: &[u8]) -> Option<&str> {
    if payload.len() < 5 {
        return None;
    }
    if payload[0] != 0x16 {
        return None;
    }
    let version_major = payload[1];
    let version_minor = payload[2];
    if version_major != 3 || version_minor > 4 {
        return None;
    }
    let record_len = u16::from_be_bytes([payload[3], payload[4]]) as usize;
    let record_end = (5 + record_len).min(payload.len());
    let mut cursor = 5;
    if cursor >= record_end || payload[cursor] != 0x01 {
        return None;
    }
    cursor += 1;
    if cursor + 3 > record_end {
        return None;
    }
    let hs_len = ((payload[cursor] as usize) << 16)
        | ((payload[cursor + 1] as usize) << 8)
        | (payload[cursor + 2] as usize);
    cursor += 3;
    let hs_end = (cursor + hs_len).min(record_end);
    if cursor + 34 > hs_end {
        return None;
    }
    cursor += 2 + 32;
    if cursor >= hs_end {
        return None;
    }
    let session_id_len = payload[cursor] as usize;
    cursor += 1 + session_id_len;
    if cursor + 2 > hs_end {
        return None;
    }
    let cipher_suites_len = u16::from_be_bytes([payload[cursor], payload[cursor + 1]]) as usize;
    cursor += 2 + cipher_suites_len;
    if cursor >= hs_end {
        return None;
    }
    let comp_methods_len = payload[cursor] as usize;
    cursor += 1 + comp_methods_len;
    if cursor + 2 > hs_end {
        return None;
    }
    let extensions_len = u16::from_be_bytes([payload[cursor], payload[cursor + 1]]) as usize;
    cursor += 2;
    let extensions_end = (cursor + extensions_len).min(hs_end);
    while cursor + 4 <= extensions_end {
        let ext_type = u16::from_be_bytes([payload[cursor], payload[cursor + 1]]);
        let ext_len = u16::from_be_bytes([payload[cursor + 2], payload[cursor + 3]]) as usize;
        cursor += 4;
        let ext_end = cursor + ext_len;
        if ext_end > extensions_end {
            break;
        }
        if ext_type == 0x0000 {
            if cursor + 2 > ext_end {
                return None;
            }
            let list_len = u16::from_be_bytes([payload[cursor], payload[cursor + 1]]) as usize;
            let mut list_cursor = cursor + 2;
            let list_end = list_cursor + list_len;
            if list_end > ext_end {
                return None;
            }
            while list_cursor + 3 <= list_end {
                let name_type = payload[list_cursor];
                let name_len =
                    u16::from_be_bytes([payload[list_cursor + 1], payload[list_cursor + 2]])
                        as usize;
                list_cursor += 3;
                if list_cursor + name_len > list_end {
                    return None;
                }
                if name_type == 0x00 {
                    let name_bytes = &payload[list_cursor..list_cursor + name_len];
                    return std::str::from_utf8(name_bytes).ok();
                }
                list_cursor += name_len;
            }
        }
        cursor = ext_end;
    }
    None
}

pub fn extract_dns_info(payload: &[u8]) -> Option<(String, bool, Vec<IpAddr>)> {
    if payload.len() < 12 {
        return None;
    }
    let flags = u16::from_be_bytes([payload[2], payload[3]]);
    let is_response = (flags & 0x8000) != 0;
    let qdcount = u16::from_be_bytes([payload[4], payload[5]]) as usize;
    let ancount = u16::from_be_bytes([payload[6], payload[7]]) as usize;
    if qdcount == 0 || qdcount > 20 {
        return None;
    }
    let mut domain = String::new();
    let mut jumped = false;
    let mut max_jumps = 5;
    let mut label_cursor = 12;
    let mut after_qname_cursor = None;

    while label_cursor < payload.len() {
        let len = payload[label_cursor] as usize;
        if len == 0 {
            if !jumped {
                label_cursor += 1;
                after_qname_cursor = Some(label_cursor);
            }
            break;
        }
        if (len & 0xc0) == 0xc0 {
            if label_cursor + 2 > payload.len() {
                return None;
            }
            if !jumped {
                after_qname_cursor = Some(label_cursor + 2);
                jumped = true;
            }
            let pointer = ((len & 0x3f) << 8) | (payload[label_cursor + 1] as usize);
            if pointer >= payload.len() || max_jumps == 0 {
                return None;
            }
            max_jumps -= 1;
            label_cursor = pointer;
            continue;
        }
        label_cursor += 1;
        if label_cursor + len > payload.len() {
            return None;
        }
        if !domain.is_empty() {
            domain.push('.');
        }
        let label_bytes = &payload[label_cursor..label_cursor + len];
        if let Ok(label_str) = std::str::from_utf8(label_bytes) {
            domain.push_str(&label_str.to_ascii_lowercase());
        } else {
            return None;
        }
        label_cursor += len;
    }

    let mut cur = after_qname_cursor?;
    if cur + 4 > payload.len() {
        return None;
    }
    cur += 4;

    let mut resolved_ips = Vec::new();
    if is_response && ancount > 0 {
        for _ in 0..ancount {
            if cur >= payload.len() {
                break;
            }
            while cur < payload.len() {
                let len = payload[cur] as usize;
                if len == 0 {
                    cur += 1;
                    break;
                }
                if (len & 0xc0) == 0xc0 {
                    cur += 2;
                    break;
                }
                cur += 1 + len;
            }
            if cur + 10 > payload.len() {
                break;
            }
            let rtype = u16::from_be_bytes([payload[cur], payload[cur + 1]]);
            let rdlength = u16::from_be_bytes([payload[cur + 8], payload[cur + 9]]) as usize;
            cur += 10;
            if cur + rdlength > payload.len() {
                break;
            }
            if rtype == 1 && rdlength == 4 {
                let ip = Ipv4Addr::new(
                    payload[cur],
                    payload[cur + 1],
                    payload[cur + 2],
                    payload[cur + 3],
                );
                resolved_ips.push(IpAddr::V4(ip));
            } else if rtype == 28 && rdlength == 16 {
                let mut ip_bytes = [0u8; 16];
                ip_bytes.copy_from_slice(&payload[cur..cur + 16]);
                let ip = Ipv6Addr::from(ip_bytes);
                resolved_ips.push(IpAddr::V6(ip));
            }
            cur += rdlength;
        }
    }

    if domain.is_empty() {
        None
    } else {
        Some((domain, is_response, resolved_ips))
    }
}

pub fn is_domain_in_list(sni: &str, direct_domains: &[String]) -> bool {
    let sni_trimmed = sni.trim_end_matches('.');
    let sni_bytes = sni_trimmed.as_bytes();
    for domain in direct_domains {
        let domain_trimmed = domain.trim().trim_end_matches('.');
        if domain_trimmed.is_empty() {
            continue;
        }
        let domain_bytes = domain_trimmed.as_bytes();
        if sni_bytes.eq_ignore_ascii_case(domain_bytes) {
            return true;
        }
        if sni_bytes.len() > domain_bytes.len()
            && sni_bytes[sni_bytes.len() - domain_bytes.len() - 1] == b'.'
            && sni_bytes[sni_bytes.len() - domain_bytes.len()..].eq_ignore_ascii_case(domain_bytes)
        {
            return true;
        }
    }
    false
}

pub fn is_direct_domain(sni: &str, direct_domains: &[String]) -> bool {
    is_domain_in_list(sni.trim_end_matches('.'), direct_domains)
}

pub fn is_direct_domain_mode(sni: &str, is_whitelist: bool, direct_domains: &[String]) -> bool {
    let sni_trimmed = sni.trim_end_matches('.');
    if is_whitelist {
        !is_domain_in_list(sni_trimmed, direct_domains)
    } else {
        is_direct_domain(sni_trimmed, direct_domains)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IpRuleSet {
    ranges: Vec<(u32, u32)>,
}

impl IpRuleSet {
    pub fn parse(input: &str) -> Self {
        let mut ranges = Vec::new();
        for token in input.split(|c: char| c.is_whitespace() || c == ',' || c == ';') {
            let cleaned = token
                .trim()
                .trim_matches(|c: char| c == ',' || c == ';' || c == '"' || c == '\'');
            if cleaned.is_empty() {
                continue;
            }
            if let Some((ip_str, prefix_str)) = cleaned.split_once('/') {
                if let Ok(ip) = ip_str.trim().parse::<Ipv4Addr>()
                    && let Ok(prefix) = prefix_str.trim().parse::<u8>()
                    && prefix <= 32
                {
                    ranges.push(cidr_bounds(u32::from(ip), prefix));
                }
            } else if let Some((start_str, end_str)) = cleaned.split_once('-') {
                if let Ok(ip1) = start_str.trim().parse::<Ipv4Addr>()
                    && let Ok(ip2) = end_str.trim().parse::<Ipv4Addr>()
                {
                    let start = u32::from(ip1);
                    let end = u32::from(ip2);
                    if start <= end {
                        ranges.push((start, end));
                    }
                }
            } else if let Ok(ip) = cleaned.parse::<Ipv4Addr>() {
                let value = u32::from(ip);
                ranges.push((value, value));
            }
        }

        ranges.sort_unstable();
        let mut merged: Vec<(u32, u32)> = Vec::with_capacity(ranges.len());
        for (start, end) in ranges {
            if let Some(last) = merged.last_mut()
                && start <= last.1.saturating_add(1)
            {
                last.1 = last.1.max(end);
                continue;
            }
            merged.push((start, end));
        }
        Self { ranges: merged }
    }

    pub fn is_empty(&self) -> bool {
        self.ranges.is_empty()
    }

    pub fn len(&self) -> usize {
        self.ranges.len()
    }

    pub fn matches(&self, ip: &IpAddr) -> bool {
        let IpAddr::V4(v4) = ip else {
            return false;
        };
        let value = u32::from(*v4);
        let index = self.ranges.partition_point(|(_, end)| *end < value);
        self.ranges
            .get(index)
            .is_some_and(|(start, _)| *start <= value)
    }
}

fn cidr_bounds(ip: u32, prefix: u8) -> (u32, u32) {
    if prefix == 0 {
        return (0, u32::MAX);
    }
    let mask = !((1u32 << (32 - prefix)) - 1);
    let network = ip & mask;
    (network, network | !mask)
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum RouteVerdict {
    Direct,
    Tunnel,
}

#[expect(clippy::too_many_arguments)]
pub fn evaluate_route(
    dst_ip: &IpAddr,
    domain: Option<&str>,
    domain_routing_enabled: bool,
    domain_is_whitelist: bool,
    direct_domains: &[String],
    ip_routing_enabled: bool,
    ip_is_whitelist: bool,
    ip_rules: &IpRuleSet,
    template_ip_rules: &IpRuleSet,
) -> RouteVerdict {
    if !domain_routing_enabled && !ip_routing_enabled {
        return RouteVerdict::Tunnel;
    }

    let ip_matches = ip_rules.matches(dst_ip) || template_ip_rules.matches(dst_ip);

    if domain_routing_enabled
        && !domain_is_whitelist
        && let Some(d) = domain
        && is_direct_domain(d, direct_domains)
    {
        return RouteVerdict::Direct;
    }

    if ip_routing_enabled && !ip_is_whitelist && ip_matches {
        return RouteVerdict::Direct;
    }

    if domain_routing_enabled
        && domain_is_whitelist
        && let Some(d) = domain
        && is_domain_in_list(d, direct_domains)
    {
        return RouteVerdict::Tunnel;
    }

    if ip_routing_enabled && ip_is_whitelist && ip_matches {
        return RouteVerdict::Tunnel;
    }

    let has_whitelist = (domain_routing_enabled && domain_is_whitelist)
        || (ip_routing_enabled
            && ip_is_whitelist
            && !(ip_rules.is_empty() && template_ip_rules.is_empty()));

    if has_whitelist {
        RouteVerdict::Direct
    } else {
        RouteVerdict::Tunnel
    }
}

pub struct DnsDomainMap {
    entries: RwLock<HashMap<IpAddr, (String, Instant)>>,
    max_entries: usize,
}

impl DnsDomainMap {
    pub fn new(max_entries: usize) -> Self {
        Self {
            entries: RwLock::new(HashMap::with_capacity(max_entries.min(4096))),
            max_entries,
        }
    }

    pub fn insert(&self, ip: IpAddr, domain: String) {
        if let Ok(mut map) = self.entries.write() {
            if map.len() >= self.max_entries {
                let now = Instant::now();
                map.retain(|_, (_, ts)| now.duration_since(*ts).as_secs() < 3600);
                if map.len() >= self.max_entries {
                    map.clear();
                }
            }
            map.insert(ip, (domain, Instant::now()));
        }
    }

    pub fn insert_multiple(&self, ips: &[IpAddr], domain: &str) {
        if ips.is_empty() {
            return;
        }
        if let Ok(mut map) = self.entries.write() {
            let now = Instant::now();
            if map.len() + ips.len() >= self.max_entries {
                map.retain(|_, (_, ts)| now.duration_since(*ts).as_secs() < 3600);
                if map.len() >= self.max_entries {
                    map.clear();
                }
            }
            let d = domain.to_string();
            for &ip in ips {
                map.insert(ip, (d.clone(), now));
            }
        }
    }

    pub fn get(&self, ip: &IpAddr) -> Option<String> {
        if let Ok(map) = self.entries.read() {
            map.get(ip).map(|(d, _)| d.clone())
        } else {
            None
        }
    }

    pub fn clear(&self) {
        if let Ok(mut map) = self.entries.write() {
            map.clear();
        }
    }
}

impl Default for DnsDomainMap {
    fn default() -> Self {
        Self::new(4096)
    }
}

pub fn parse_direct_domains(input: &str) -> Vec<String> {
    let mut result = Vec::new();
    for token in input.split(|c: char| c.is_whitespace() || c == ',' || c == ';') {
        let mut cleaned = token.trim();
        if cleaned.is_empty() {
            continue;
        }
        if let Some(pos) = cleaned.find("://") {
            cleaned = &cleaned[pos + 3..];
        }
        if let Some(pos) = cleaned.find('/') {
            cleaned = &cleaned[..pos];
        }
        if let Some(pos) = cleaned.find(':') {
            cleaned = &cleaned[..pos];
        }
        if cleaned.to_ascii_lowercase().starts_with("www.") {
            cleaned = &cleaned[4..];
        }
        let cleaned_domain = cleaned
            .trim_matches(|c: char| c == '.' || c == ',' || c == ';' || c.is_whitespace())
            .to_lowercase();
        if cleaned_domain.len() >= 3
            && cleaned_domain.contains('.')
            && !result.contains(&cleaned_domain)
        {
            result.push(cleaned_domain);
        }
    }
    result
}

pub fn parse_ip_packet_sni(packet: &[u8]) -> Option<(&str, u16)> {
    if packet.is_empty() {
        return None;
    }
    let version = packet[0] >> 4;
    let (ihl, protocol, total_len) = match version {
        4 => {
            if packet.len() < 20 {
                return None;
            }
            let ihl = (packet[0] & 0x0f) as usize * 4;
            if ihl < 20 || ihl > packet.len() {
                return None;
            }
            let protocol = packet[9];
            let total_len = u16::from_be_bytes([packet[2], packet[3]]) as usize;
            (ihl, protocol, total_len.min(packet.len()))
        }
        6 => {
            if packet.len() < 40 {
                return None;
            }
            let protocol = packet[6];
            let payload_len = u16::from_be_bytes([packet[4], packet[5]]) as usize;
            (40, protocol, (40 + payload_len).min(packet.len()))
        }
        _ => return None,
    };
    if protocol != 6 || total_len <= ihl {
        return None;
    }
    let tcp_slice = &packet[ihl..total_len];
    if tcp_slice.len() < 20 {
        return None;
    }
    let dest_port = u16::from_be_bytes([tcp_slice[2], tcp_slice[3]]);
    let data_offset = ((tcp_slice[12] >> 4) as usize) * 4;
    if tcp_slice.len() <= data_offset {
        return None;
    }
    let payload = &tcp_slice[data_offset..];
    extract_tls_sni(payload).map(|sni| (sni, dest_port))
}

pub fn parse_ip_packet_dns(packet: &[u8]) -> Option<(String, bool, Vec<IpAddr>)> {
    if packet.is_empty() {
        return None;
    }
    let version = packet[0] >> 4;
    let (ihl, protocol, total_len) = match version {
        4 => {
            if packet.len() < 20 {
                return None;
            }
            let ihl = (packet[0] & 0x0f) as usize * 4;
            if ihl < 20 || ihl > packet.len() {
                return None;
            }
            let protocol = packet[9];
            let total_len = u16::from_be_bytes([packet[2], packet[3]]) as usize;
            (ihl, protocol, total_len.min(packet.len()))
        }
        6 => {
            if packet.len() < 40 {
                return None;
            }
            let protocol = packet[6];
            let payload_len = u16::from_be_bytes([packet[4], packet[5]]) as usize;
            (40, protocol, (40 + payload_len).min(packet.len()))
        }
        _ => return None,
    };
    if protocol != 17 || total_len <= ihl {
        return None;
    }
    let udp_slice = &packet[ihl..total_len];
    if udp_slice.len() < 8 {
        return None;
    }
    let src_port = u16::from_be_bytes([udp_slice[0], udp_slice[1]]);
    let dst_port = u16::from_be_bytes([udp_slice[2], udp_slice[3]]);
    if src_port != 53 && dst_port != 53 {
        return None;
    }
    let udp_len = u16::from_be_bytes([udp_slice[4], udp_slice[5]]) as usize;
    if udp_slice.len() < udp_len || udp_len < 8 {
        return None;
    }
    let payload = &udp_slice[8..udp_len];
    extract_dns_info(payload)
}

pub fn extract_dst_addr(packet: &[u8]) -> Option<SocketAddr> {
    if packet.is_empty() {
        return None;
    }
    let version = packet[0] >> 4;
    match version {
        4 => {
            if packet.len() < 20 {
                return None;
            }
            let ihl = (packet[0] & 0x0f) as usize * 4;
            if ihl < 20 || ihl > packet.len() {
                return None;
            }
            let protocol = packet[9];
            let dst_ip = Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]);
            if (protocol == 6 || protocol == 17) && packet.len() >= ihl + 4 {
                let dst_port = u16::from_be_bytes([packet[ihl + 2], packet[ihl + 3]]);
                Some(SocketAddr::V4(SocketAddrV4::new(dst_ip, dst_port)))
            } else {
                Some(SocketAddr::new(IpAddr::V4(dst_ip), 0))
            }
        }
        6 => {
            if packet.len() < 40 {
                return None;
            }
            let protocol = packet[6];
            let mut ip_bytes = [0u8; 16];
            ip_bytes.copy_from_slice(&packet[24..40]);
            let dst_ip = Ipv6Addr::from(ip_bytes);
            if (protocol == 6 || protocol == 17) && packet.len() >= 44 {
                let dst_port = u16::from_be_bytes([packet[42], packet[43]]);
                Some(SocketAddr::V6(SocketAddrV6::new(dst_ip, dst_port, 0, 0)))
            } else {
                Some(SocketAddr::new(IpAddr::V6(dst_ip), 0))
            }
        }
        _ => None,
    }
}

pub fn extract_src_addr(packet: &[u8]) -> Option<SocketAddr> {
    if packet.is_empty() {
        return None;
    }
    let version = packet[0] >> 4;
    match version {
        4 => {
            if packet.len() < 20 {
                return None;
            }
            let ihl = (packet[0] & 0x0f) as usize * 4;
            if ihl < 20 || ihl > packet.len() {
                return None;
            }
            let protocol = packet[9];
            let src_ip = Ipv4Addr::new(packet[12], packet[13], packet[14], packet[15]);
            if (protocol == 6 || protocol == 17) && packet.len() >= ihl + 4 {
                let src_port = u16::from_be_bytes([packet[ihl], packet[ihl + 1]]);
                Some(SocketAddr::V4(SocketAddrV4::new(src_ip, src_port)))
            } else {
                Some(SocketAddr::new(IpAddr::V4(src_ip), 0))
            }
        }
        6 => {
            if packet.len() < 40 {
                return None;
            }
            let protocol = packet[6];
            let mut ip_bytes = [0u8; 16];
            ip_bytes.copy_from_slice(&packet[8..24]);
            let src_ip = Ipv6Addr::from(ip_bytes);
            if (protocol == 6 || protocol == 17) && packet.len() >= 44 {
                let src_port = u16::from_be_bytes([packet[40], packet[41]]);
                Some(SocketAddr::V6(SocketAddrV6::new(src_ip, src_port, 0, 0)))
            } else {
                Some(SocketAddr::new(IpAddr::V6(src_ip), 0))
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::any;

    #[test]
    fn test_direct_domain_matching() {
        let custom = vec!["discord.com".to_string(), "telegram.org".to_string()];
        assert!(is_direct_domain("discord.com", &custom));
        assert!(is_direct_domain("cdn.discord.com", &custom));
        assert!(is_direct_domain("telegram.org", &custom));
        assert!(is_direct_domain("api.telegram.org", &custom));
        assert!(!is_direct_domain("google.com", &custom));
        assert!(!is_direct_domain("yandex.ru", &custom));
        assert!(!is_direct_domain("yandex.net", &custom));
    }

    #[test]
    fn test_parse_direct_domains() {
        let newline_input = "yandex.ru\nmail.ru\nkinopoisk.ru";
        let parsed = parse_direct_domains(newline_input);
        assert_eq!(parsed, vec!["yandex.ru", "mail.ru", "kinopoisk.ru"]);

        let comma_space_input = "yandex.ru, mail.ru, kinopoisk.ru";
        let parsed = parse_direct_domains(comma_space_input);
        assert_eq!(parsed, vec!["yandex.ru", "mail.ru", "kinopoisk.ru"]);

        let comma_no_space_input = "yandex.ru,mail.ru,kinopoisk.ru";
        let parsed = parse_direct_domains(comma_no_space_input);
        assert_eq!(parsed, vec!["yandex.ru", "mail.ru", "kinopoisk.ru"]);

        let space_input = "yandex.ru mail.ru kinopoisk.ru";
        let parsed = parse_direct_domains(space_input);
        assert_eq!(parsed, vec!["yandex.ru", "mail.ru", "kinopoisk.ru"]);

        let mixed_input = "https://yandex.ru/internet, http://www.mail.ru:8080/test; kinopoisk.ru\ndzen.ru ivi.ru";
        let parsed = parse_direct_domains(mixed_input);
        assert_eq!(
            parsed,
            vec!["yandex.ru", "mail.ru", "kinopoisk.ru", "dzen.ru", "ivi.ru"]
        );

        let dirty_input = ",,   \n\n  http://,, .ru, test.com, test.com, ";
        let parsed = parse_direct_domains(dirty_input);
        assert_eq!(parsed, vec!["test.com"]);
    }

    #[test]
    fn test_tls_sni_extraction() {
        let hostname = b"kremlin.ru";
        let mut valid_fixture = Vec::new();
        valid_fixture.extend_from_slice(&[0x16, 0x03, 0x01]);
        let rec_len = (4 + 2 + 32 + 1 + 4 + 2 + 2 + 4 + 2 + 1 + 2 + hostname.len()) as u16;
        valid_fixture.extend_from_slice(&rec_len.to_be_bytes());
        valid_fixture.push(0x01);
        let hs_len = (2 + 32 + 1 + 4 + 2 + 2 + 4 + 2 + 1 + 2 + hostname.len()) as u32;
        valid_fixture.push(((hs_len >> 16) & 0xff) as u8);
        valid_fixture.push(((hs_len >> 8) & 0xff) as u8);
        valid_fixture.push((hs_len & 0xff) as u8);
        valid_fixture.extend_from_slice(&[0x03, 0x03]);
        valid_fixture.extend_from_slice(&[0xaa; 32]);
        valid_fixture.push(0x00);
        valid_fixture.extend_from_slice(&[0x00, 0x02, 0x13, 0x01]);
        valid_fixture.extend_from_slice(&[0x01, 0x00]);
        let ext_total_len = (4 + 2 + 1 + 2 + hostname.len()) as u16;
        valid_fixture.extend_from_slice(&ext_total_len.to_be_bytes());
        valid_fixture.extend_from_slice(&[0x00, 0x00]);
        let sni_data_len = (2 + 1 + 2 + hostname.len()) as u16;
        valid_fixture.extend_from_slice(&sni_data_len.to_be_bytes());
        let list_len = (1 + 2 + hostname.len()) as u16;
        valid_fixture.extend_from_slice(&list_len.to_be_bytes());
        valid_fixture.push(0x00);
        let name_len = hostname.len() as u16;
        valid_fixture.extend_from_slice(&name_len.to_be_bytes());
        valid_fixture.extend_from_slice(hostname);

        let extracted = extract_tls_sni(&valid_fixture);
        assert_eq!(extracted, Some("kremlin.ru"));
    }

    #[test]
    fn test_tls_sni_extraction_from_ip_packet() {
        let hostname = b"yandex.ru";
        let mut tls = Vec::new();
        tls.extend_from_slice(&[0x16, 0x03, 0x01]);
        let rec_len = (4 + 2 + 32 + 1 + 4 + 2 + 2 + 4 + 2 + 1 + 2 + hostname.len()) as u16;
        tls.extend_from_slice(&rec_len.to_be_bytes());
        tls.push(0x01);
        let hs_len = (2 + 32 + 1 + 4 + 2 + 2 + 4 + 2 + 1 + 2 + hostname.len()) as u32;
        tls.push(((hs_len >> 16) & 0xff) as u8);
        tls.push(((hs_len >> 8) & 0xff) as u8);
        tls.push((hs_len & 0xff) as u8);
        tls.extend_from_slice(&[0x03, 0x03]);
        tls.extend_from_slice(&[0xbb; 32]);
        tls.push(0x00);
        tls.extend_from_slice(&[0x00, 0x02, 0x13, 0x01]);
        tls.extend_from_slice(&[0x01, 0x00]);
        let ext_total_len = (4 + 2 + 1 + 2 + hostname.len()) as u16;
        tls.extend_from_slice(&ext_total_len.to_be_bytes());
        tls.extend_from_slice(&[0x00, 0x00]);
        let sni_data_len = (2 + 1 + 2 + hostname.len()) as u16;
        tls.extend_from_slice(&sni_data_len.to_be_bytes());
        let list_len = (1 + 2 + hostname.len()) as u16;
        tls.extend_from_slice(&list_len.to_be_bytes());
        tls.push(0x00);
        let name_len = hostname.len() as u16;
        tls.extend_from_slice(&name_len.to_be_bytes());
        tls.extend_from_slice(hostname);

        let mut ip_packet = Vec::new();
        let ip_len = (20 + 20 + tls.len()) as u16;
        ip_packet.push(0x45);
        ip_packet.push(0x00);
        ip_packet.extend_from_slice(&ip_len.to_be_bytes());
        ip_packet.extend_from_slice(&[0x00, 0x01, 0x00, 0x00, 0x40, 0x06, 0x00, 0x00]);
        ip_packet.extend_from_slice(&[10, 0, 0, 2]);
        ip_packet.extend_from_slice(&[77, 88, 55, 60]);

        ip_packet.extend_from_slice(&[0xcd, 0x12]);
        ip_packet.extend_from_slice(&[0x01, 0xbb]);
        ip_packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]);
        ip_packet.push(0x50);
        ip_packet.push(0x18);
        ip_packet.extend_from_slice(&[0x10, 0x00, 0x00, 0x00, 0x00, 0x00]);

        ip_packet.extend_from_slice(&tls);

        let res = parse_ip_packet_sni(&ip_packet);
        assert_eq!(res, Some(("yandex.ru", 443)));
        let dst = extract_dst_addr(&ip_packet).unwrap();
        assert_eq!(dst.to_string(), "77.88.55.60:443");
    }

    #[test]
    fn test_dns_query_parsing() {
        let mut dns_payload = Vec::new();
        dns_payload.extend_from_slice(&[0x12, 0x34]);
        dns_payload.extend_from_slice(&[0x01, 0x00]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x00]);
        dns_payload.extend_from_slice(&[0x00, 0x00]);
        dns_payload.extend_from_slice(&[0x00, 0x00]);

        dns_payload.push(6);
        dns_payload.extend_from_slice(b"yandex");
        dns_payload.push(2);
        dns_payload.extend_from_slice(b"ru");
        dns_payload.push(0);

        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);

        let (domain, is_resp, ips) = extract_dns_info(&dns_payload).unwrap();
        assert_eq!(domain, "yandex.ru");
        assert!(!is_resp);
        assert!(ips.is_empty());
    }

    #[test]
    fn test_dns_response_parsing_with_ips() {
        let mut dns_payload = Vec::new();
        dns_payload.extend_from_slice(&[0x12, 0x34]);
        dns_payload.extend_from_slice(&[0x81, 0x80]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x00]);
        dns_payload.extend_from_slice(&[0x00, 0x00]);

        dns_payload.push(6);
        dns_payload.extend_from_slice(b"yandex");
        dns_payload.push(2);
        dns_payload.extend_from_slice(b"ru");
        dns_payload.push(0);

        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);

        dns_payload.extend_from_slice(&[0xc0, 0x0c]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x01]);
        dns_payload.extend_from_slice(&[0x00, 0x00, 0x01, 0x2c]);
        dns_payload.extend_from_slice(&[0x00, 0x04]);
        dns_payload.extend_from_slice(&[77, 88, 55, 60]);

        let (domain, is_resp, ips) = extract_dns_info(&dns_payload).unwrap();
        assert_eq!(domain, "yandex.ru");
        assert!(is_resp);
        assert_eq!(ips, vec![IpAddr::V4(Ipv4Addr::new(77, 88, 55, 60))]);
    }

    #[test]
    fn test_ip_packet_dns_query_and_response() {
        let mut dns_query = Vec::new();
        dns_query.extend_from_slice(&[0xab, 0xcd]);
        dns_query.extend_from_slice(&[0x01, 0x00]);
        dns_query.extend_from_slice(&[0x00, 0x01]);
        dns_query.extend_from_slice(&[0x00, 0x00]);
        dns_query.extend_from_slice(&[0x00, 0x00]);
        dns_query.extend_from_slice(&[0x00, 0x00]);

        dns_query.push(4);
        dns_query.extend_from_slice(b"mail");
        dns_query.push(2);
        dns_query.extend_from_slice(b"ru");
        dns_query.push(0);
        dns_query.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]);

        let udp_len = (8 + dns_query.len()) as u16;
        let mut udp = Vec::new();
        udp.extend_from_slice(&[0xca, 0xfe]);
        udp.extend_from_slice(&[0x00, 0x35]);
        udp.extend_from_slice(&udp_len.to_be_bytes());
        udp.extend_from_slice(&[0x00, 0x00]);
        udp.extend_from_slice(&dns_query);

        let ip_len = (20 + udp.len()) as u16;
        let mut ip_pkt = Vec::new();
        ip_pkt.push(0x45);
        ip_pkt.push(0x00);
        ip_pkt.extend_from_slice(&ip_len.to_be_bytes());
        ip_pkt.extend_from_slice(&[0x00, 0x02, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00]);
        ip_pkt.extend_from_slice(&[10, 0, 0, 2]);
        ip_pkt.extend_from_slice(&[1, 1, 1, 1]);
        ip_pkt.extend_from_slice(&udp);

        let parsed = parse_ip_packet_dns(&ip_pkt);
        assert!(parsed.is_some());
        let (domain, is_resp, _) = parsed.unwrap();
        assert_eq!(domain, "mail.ru");
        assert!(!is_resp);
    }

    #[test]
    fn test_domain_whitelist_inversion_direct_routing() {
        let white_domains = vec!["special.com".to_string(), "vpn-only.org".to_string()];
        assert!(!is_direct_domain_mode("special.com", true, &white_domains));
        assert!(!is_direct_domain_mode(
            "sub.special.com",
            true,
            &white_domains
        ));
        assert!(!is_direct_domain_mode("vpn-only.org", true, &white_domains));
        assert!(is_direct_domain_mode("google.com", true, &white_domains));
        assert!(is_direct_domain_mode("yandex.ru", true, &white_domains));
    }

    #[test]
    fn test_domain_blacklist_direct_routing() {
        let black_domains = vec!["blocked.com".to_string(), "direct.org".to_string()];
        assert!(is_direct_domain_mode("blocked.com", false, &black_domains));
        assert!(is_direct_domain_mode(
            "sub.blocked.com",
            false,
            &black_domains
        ));
        assert!(!is_direct_domain_mode("normal.com", false, &black_domains));
    }

    fn ip_verdict(ip: &IpAddr, enabled: bool, whitelist: bool, rules: &IpRuleSet) -> RouteVerdict {
        evaluate_route(
            ip,
            None,
            false,
            false,
            &[],
            enabled,
            whitelist,
            rules,
            &IpRuleSet::default(),
        )
    }

    #[test]
    fn test_ip_direct_mode_blacklist_and_whitelist() {
        let rules = IpRuleSet::parse("1.1.1.1, 10.0.0.0/24, 172.16.0.10-172.16.0.20");
        let ip_1_1_1_1 = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        let ip_10_0_0_50 = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 50));
        let ip_172_16_0_15 = IpAddr::V4(Ipv4Addr::new(172, 16, 0, 15));
        let ip_8_8_8_8 = IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8));

        assert_eq!(
            ip_verdict(&ip_1_1_1_1, true, false, &rules),
            RouteVerdict::Direct
        );
        assert_eq!(
            ip_verdict(&ip_10_0_0_50, true, false, &rules),
            RouteVerdict::Direct
        );
        assert_eq!(
            ip_verdict(&ip_172_16_0_15, true, false, &rules),
            RouteVerdict::Direct
        );
        assert_eq!(
            ip_verdict(&ip_8_8_8_8, true, false, &rules),
            RouteVerdict::Tunnel
        );

        assert_eq!(
            ip_verdict(&ip_1_1_1_1, true, true, &rules),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            ip_verdict(&ip_10_0_0_50, true, true, &rules),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            ip_verdict(&ip_172_16_0_15, true, true, &rules),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            ip_verdict(&ip_8_8_8_8, true, true, &rules),
            RouteVerdict::Direct
        );

        assert_eq!(
            ip_verdict(&ip_1_1_1_1, false, false, &rules),
            RouteVerdict::Tunnel
        );
    }

    #[test]
    fn test_ip_edge_cases_cidr_0_and_32_and_invalid_ranges() {
        let rules_cidr0 = IpRuleSet::parse("0.0.0.0/0");
        let ip1 = IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4));
        let ip2 = IpAddr::V4(Ipv4Addr::new(255, 255, 255, 255));
        assert_eq!(
            ip_verdict(&ip1, true, false, &rules_cidr0),
            RouteVerdict::Direct
        );
        assert_eq!(
            ip_verdict(&ip2, true, false, &rules_cidr0),
            RouteVerdict::Direct
        );

        let rules_cidr32 = IpRuleSet::parse("192.168.1.100/32");
        let ip_match = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 100));
        let ip_no_match = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 101));
        assert_eq!(
            ip_verdict(&ip_match, true, false, &rules_cidr32),
            RouteVerdict::Direct
        );
        assert_eq!(
            ip_verdict(&ip_no_match, true, false, &rules_cidr32),
            RouteVerdict::Tunnel
        );

        let invalid_and_valid = IpRuleSet::parse("10.0.0.20-10.0.0.10 8.8.8.8");
        let ip_mid = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 15));
        assert_eq!(
            ip_verdict(&ip_mid, true, false, &invalid_and_valid),
            RouteVerdict::Tunnel
        );
    }

    #[test]
    fn test_dns_domain_map() {
        let map = DnsDomainMap::new(10);
        let ip1 = IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4));
        let ip2 = IpAddr::V4(Ipv4Addr::new(5, 6, 7, 8));

        map.insert(ip1, "example.com".to_string());
        assert_eq!(map.get(&ip1), Some("example.com".to_string()));
        assert_eq!(map.get(&ip2), None);

        map.insert_multiple(&[ip2], "vk.com");
        assert_eq!(map.get(&ip2), Some("vk.com".to_string()));
    }

    #[test]
    fn test_evaluate_route_universal_matrix() {
        let ip_rules = IpRuleSet::parse("1.1.1.1, 10.0.0.0/8, 172.16.0.0/16");
        let template = IpRuleSet::default();
        let direct_domains = vec!["vk.com".to_string(), "yandex.ru".to_string()];
        let route = |ip: &IpAddr,
                     domain: Option<&str>,
                     domains: bool,
                     whitelist: bool,
                     ips: bool,
                     ip_whitelist: bool| {
            evaluate_route(
                ip,
                domain,
                domains,
                whitelist,
                &direct_domains,
                ips,
                ip_whitelist,
                &ip_rules,
                &template,
            )
        };

        let ip_1_1_1_1 = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        let ip_10_1_2_3 = IpAddr::V4(Ipv4Addr::new(10, 1, 2, 3));
        let ip_8_8_8_8 = IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8));
        let ip_77_88_8_8 = IpAddr::V4(Ipv4Addr::new(77, 88, 8, 8));

        assert_eq!(
            route(&ip_1_1_1_1, Some("vk.com"), false, false, false, false),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("vk.com"), true, false, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_77_88_8_8, Some("gosuslugi.ru"), true, false, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_1_1_1_1, Some("google.com"), true, false, true, true),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_10_1_2_3, None, true, false, true, true),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("cloudflare.com"), true, false, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_8_8_8_8, None, true, false, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_1_1_1_1, Some("vk.com"), true, false, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("vk.com"), true, false, true, false),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_1_1_1_1, Some("google.com"), true, false, true, false),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("google.com"), true, false, true, false),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("vk.com"), true, true, true, true),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_1_1_1_1, Some("unlisted.com"), true, true, true, true),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("unlisted.com"), true, true, true, true),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_1_1_1_1, Some("vk.com"), true, true, true, false),
            RouteVerdict::Direct
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("vk.com"), true, true, true, false),
            RouteVerdict::Tunnel
        );
        assert_eq!(
            route(&ip_8_8_8_8, Some("unlisted.com"), true, true, true, false),
            RouteVerdict::Direct
        );
    }

    #[test]
    fn test_evaluate_route_user_reported_scenario() {
        let ip_rules = IpRuleSet::parse("193.106.141.229");
        let template = IpRuleSet::default();
        let direct_domains = vec!["notion.so".to_string()];

        let ping_eu_ip = IpAddr::V4(Ipv4Addr::new(193, 106, 141, 229));
        let yandex_ip = IpAddr::V4(Ipv4Addr::new(77, 88, 55, 66));
        let notion_ip = IpAddr::V4(Ipv4Addr::new(104, 18, 20, 50));

        assert_eq!(
            evaluate_route(
                &yandex_ip,
                Some("yandex.ru"),
                true,
                true,
                &direct_domains,
                true,
                true,
                &ip_rules,
                &template,
            ),
            RouteVerdict::Direct,
            "yandex.ru must go Direct when not in whitelists"
        );
        assert_eq!(
            evaluate_route(
                &yandex_ip,
                None,
                true,
                true,
                &direct_domains,
                true,
                true,
                &ip_rules,
                &template,
            ),
            RouteVerdict::Direct,
            "yandex IP must go Direct when not in IP whitelist"
        );
        assert_eq!(
            evaluate_route(
                &notion_ip,
                Some("notion.so"),
                true,
                true,
                &direct_domains,
                true,
                true,
                &ip_rules,
                &template,
            ),
            RouteVerdict::Tunnel,
            "notion.so must go Tunnel because it is in domain whitelist"
        );
        assert_eq!(
            evaluate_route(
                &ping_eu_ip,
                Some("ping.eu"),
                true,
                true,
                &direct_domains,
                true,
                true,
                &ip_rules,
                &template,
            ),
            RouteVerdict::Tunnel,
            "ping.eu must go Tunnel because its IP is in IP whitelist"
        );
        assert_eq!(
            evaluate_route(
                &ping_eu_ip,
                None,
                true,
                true,
                &direct_domains,
                true,
                true,
                &ip_rules,
                &template,
            ),
            RouteVerdict::Tunnel,
            "ping.eu IP with None domain must go Tunnel because it matches IP whitelist"
        );
    }

    #[test]
    fn evaluate_route_matches_the_union_of_explicit_and_template_rules() {
        let explicit = IpRuleSet::parse("1.1.1.1");
        let template = IpRuleSet::parse("10.0.0.0/8");
        let verdict = |ip: &str| {
            evaluate_route(
                &ip.parse().unwrap(),
                None,
                false,
                false,
                &[],
                true,
                false,
                &explicit,
                &template,
            )
        };
        assert_eq!(verdict("10.1.1.1"), RouteVerdict::Direct);
        assert_eq!(verdict("1.1.1.1"), RouteVerdict::Direct);
        assert_eq!(verdict("8.8.8.8"), RouteVerdict::Tunnel);
    }

    #[test]
    fn a_trailing_dot_and_subdomain_still_match_the_explicit_domain_list() {
        let direct = vec!["example.com".to_string()];
        assert!(is_direct_domain("example.com.", &direct));
        assert!(is_direct_domain("www.example.com", &direct));
        assert!(is_direct_domain_mode("api.example.com.", false, &direct));
        assert!(!is_direct_domain_mode("api.example.com.", true, &direct));
    }

    #[test]
    fn ip_rule_set_merges_ranges_and_searches_like_a_linear_scan() {
        let set = IpRuleSet::parse("10.0.0.0/8, 10.1.2.3, 192.168.1.1-192.168.1.50, 192.168.1.51");
        assert!(set.matches(&"10.1.2.3".parse().unwrap()));
        assert!(set.matches(&"192.168.1.50".parse().unwrap()));
        assert!(set.matches(&"192.168.1.51".parse().unwrap()));
        assert!(!set.matches(&"11.0.0.1".parse().unwrap()));
        assert!(!set.matches(&"::1".parse().unwrap()));
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn ip_rule_set_treats_garbage_as_an_empty_set() {
        assert!(IpRuleSet::parse("").is_empty());
        assert!(IpRuleSet::parse("   ").is_empty());
        assert!(IpRuleSet::parse("not-an-ip").is_empty());
        assert!(IpRuleSet::parse("10.0.0.0/33").is_empty());
        assert!(IpRuleSet::parse("10.0.0.20-10.0.0.10").is_empty());
    }

    fn cidr_bounds_for_test(ip: u32, prefix: u8) -> (u32, u32) {
        if prefix == 0 {
            return (0, u32::MAX);
        }
        let mask = !((1u32 << (32 - prefix)) - 1);
        let network = ip & mask;
        (network, network | !mask)
    }

    fn format_proptest_rule(start: u32, end: u32) -> String {
        if start == end {
            return Ipv4Addr::from(start).to_string();
        }
        for prefix in 0..=32u8 {
            if cidr_bounds_for_test(start, prefix) == (start, end) {
                return format!("{}/{}", Ipv4Addr::from(start), prefix);
            }
        }
        format!("{}-{}", Ipv4Addr::from(start), Ipv4Addr::from(end))
    }

    fn arbitrary_interval() -> impl proptest::prelude::Strategy<Value = (u32, u32)> {
        use proptest::prelude::*;
        prop_oneof![
            any::<u32>().prop_map(|value| (value, value)),
            (any::<u32>(), any::<u32>()).prop_map(|(a, b)| if a <= b { (a, b) } else { (b, a) }),
            (any::<u32>(), 0u8..=32).prop_map(|(base, prefix)| cidr_bounds_for_test(base, prefix)),
        ]
    }

    proptest::proptest! {
        #[test]
        fn ip_rule_set_matches_a_linear_oracle(
            rules in proptest::collection::vec(arbitrary_interval(), 0..16),
            probes in proptest::collection::vec(any::<u32>(), 0..32),
        ) {
            let text = rules
                .iter()
                .map(|&(start, end)| format_proptest_rule(start, end))
                .collect::<Vec<_>>()
                .join(",");
            let set = IpRuleSet::parse(&text);
            let mut values = probes;
            for (start, end) in &rules {
                values.push(*start);
                values.push(*end);
                values.push(start.wrapping_sub(1));
                values.push(end.wrapping_add(1));
            }
            for value in values {
                let expected = rules.iter().any(|(start, end)| *start <= value && value <= *end);
                proptest::prop_assert_eq!(
                    set.matches(&IpAddr::V4(Ipv4Addr::from(value))),
                    expected,
                    "value {} text {}",
                    value,
                    text
                );
            }
        }
    }
}
