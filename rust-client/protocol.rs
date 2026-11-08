use anyhow::{Result, bail};

use crate::wire_protocol::PATH_ECHO_PREFIX;

pub const PANEL_RESTART_NOTICE: &[u8] = b"\xffCSQTT_PANEL_RESTART_V1\x00\x91\x7d\x03\xa8";
/// «Правило маршрутизации изменилось» — зеркало серверного
/// `protocol::ROUTING_CHANGED_NOTICE`, байт в байт.
///
/// Сервер шлёт его живым сессиям после правки или отвязки правила, чтобы
/// config-owner повторил `GETCONF`, не дожидаясь переподключения. Старый сервер
/// этот бинарь не отправляет вовсе, а новый сервер → старый клиент: неизвестный
/// пакет, который тот молча отбрасывает как не-IP — деградация в обе стороны
/// безопасна.
pub const ROUTING_CHANGED_NOTICE: &[u8] = b"\xffCSQTT_ROUTING_CHANGED_V1\x00\x5c\x2a\xef\x19";
pub const STREAM_REPAIR_PREFIX: &[u8] = b"\xffCSQTT_STREAM_REPAIR_V1";
pub const STREAM_ALIVE_PREFIX: &[u8] = b"\xffCSQTT_STREAM_ALIVE_V1";
/// `ROUTING:ABSENT` — у подключения нет правила маршрутизации. Лежит в
/// семействе `ROUTING:`, поэтому считается управляющим пакетом; рессемблер
/// такой формат не разбирает, и старые клиенты его молча отбрасывают.
pub const ROUTING_ABSENT: &[u8] = b"ROUTING:ABSENT";
const MAX_STREAM_WORKERS: u16 = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigResponse {
    Config(String),
    NoConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamRepairCommand {
    pub sequence: u64,
    pub desired_count: u16,
    pub worker_ids: Vec<u16>,
}

/// Тестовый помощник для формы без кеша доменов/приложений.
#[cfg(test)]
#[expect(clippy::too_many_arguments)]
pub fn config_request(
    local_port: &str,
    password: &str,
    generation_id: u64,
    salt: &str,
    worker_id: usize,
    desired_count: Option<usize>,
    config_owner: bool,
    routing_ips_sha: Option<&str>,
) -> String {
    config_request_with_content(
        local_port,
        password,
        generation_id,
        salt,
        worker_id,
        desired_count,
        config_owner,
        routing_ips_sha,
        None,
        false,
    )
}

const ROUTING2_CAPABILITY: &str = "routing2";

#[expect(clippy::too_many_arguments)]
pub fn config_request_with_content(
    local_port: &str,
    password: &str,
    generation_id: u64,
    salt: &str,
    worker_id: usize,
    desired_count: Option<usize>,
    config_owner: bool,
    routing_ips_sha: Option<&str>,
    routing_content_sha: Option<&str>,
    advertise_routing2: bool,
) -> String {
    let desired_count = desired_count.map_or_else(String::new, |value| value.to_string());
    let base = format!(
        "GETCONF:{local_port}|{password}|{generation_id}|{salt}|{worker_id}|{desired_count}"
    );
    if config_owner {
        // Только config-owner просит сервер прислать решение о маршрутизации:
        // остальные воркеры получают голый TUNCONF. Поля добавлены в конец,
        // поэтому старый сервер их игнорирует, а новый без них обслуживает
        // клиента по-прежнему — один раз на поколение. Восьмое поле — sha
        // закешированного адресного списка, девятое — sha кеша доменов и
        // приложений; не-owner их не читает и не получает. Пустые восьмое и
        // девятое поля нужны, чтобы метка `routing2` осталась десятой.
        if advertise_routing2 {
            return format!(
                "{base}|owner|{}|{}|{ROUTING2_CAPABILITY}",
                routing_ips_sha.unwrap_or(""),
                routing_content_sha.unwrap_or("")
            );
        }
        match (routing_ips_sha, routing_content_sha) {
            (None, None) => format!("{base}|owner"),
            (Some(ips), None) => format!("{base}|owner|{ips}"),
            (None, Some(content)) => format!("{base}|owner||{content}"),
            (Some(ips), Some(content)) => format!("{base}|owner|{ips}|{content}"),
        }
    } else if advertise_routing2 {
        // Воркер тоже объявляет формат: сервер может отправить ему legacy-доставку.
        format!("{base}|{ROUTING2_CAPABILITY}")
    } else {
        base
    }
}

/// Пакет доставки правила: старый `ROUTING:` или `ROUTING2:` с nonce.
pub fn is_routing_delivery(payload: &[u8]) -> bool {
    payload.starts_with(b"ROUTING:") || payload.starts_with(b"ROUTING2:")
}

pub fn parse_routing_ips_sha(value: &str) -> Option<String> {
    let normalized = value.trim().to_ascii_lowercase();
    (normalized.len() == 64 && normalized.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then_some(normalized)
}

/// Sha кеша доменов и приложений — та же форма, что у адресного.
pub fn parse_routing_content_sha(value: &str) -> Option<String> {
    parse_routing_ips_sha(value)
}

/// Прочитать sha кеша из живого файла.
///
/// Файл, а не argv: приложение перезаписывает кеш в середине сессии, и
/// следующий GETCONF обязан унести новый sha. Ошибка чтения/формата — «кеша
/// нет»: сервер пришлёт полный набор, это безопасно.
pub fn read_routing_content_sha(path: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    parse_routing_content_sha(&raw)
}

pub fn parse_config_response(response: &[u8]) -> Result<ConfigResponse> {
    let response = std::str::from_utf8(response)?;
    if response == "NOCONF" {
        return Ok(ConfigResponse::NoConfig);
    }
    if let Some(reason) = response.strip_prefix("DENIED:") {
        match reason {
            "wrong_password" => bail!("FATAL_AUTH: неверный пароль подключения"),
            "expired" => bail!("FATAL_AUTH: срок действия пароля истёк"),
            "deactivated" => bail!("FATAL_AUTH: аккаунт деактивирован"),
            "protocol_mismatch" => bail!(
                "FATAL_PROTOCOL: клиент и сервер используют разные версии протокола; выполните деплой из этой версии приложения"
            ),
            "invalid_worker_count" => bail!("превышен лимит потоков"),
            _ => bail!("доступ отклонён сервером ({reason})"),
        }
    }
    if response.starts_with("TUNCONF:") {
        return Ok(ConfigResponse::Config(response.to_owned()));
    }
    bail!("unexpected GETCONF response")
}

pub fn is_config_response(response: &[u8]) -> bool {
    [
        b"TUNCONF:".as_slice(),
        b"NOCONF".as_slice(),
        b"DENIED:".as_slice(),
    ]
    .iter()
    .any(|prefix| response.starts_with(prefix))
}

pub fn is_control_response(response: &[u8]) -> bool {
    if is_panel_restart_notice(response) || is_routing_changed_notice(response) {
        return true;
    }
    [
        b"TUNCONF:".as_slice(),
        b"NOCONF".as_slice(),
        b"DENIED:".as_slice(),
        b"READY_OK".as_slice(),
        b"OK:disconnected".as_slice(),
        b"ROUTING:".as_slice(),
        b"ROUTING2:".as_slice(),
        b"TUNWORKERS:".as_slice(),
        b"WORKERS:".as_slice(),
        STREAM_REPAIR_PREFIX,
        STREAM_ALIVE_PREFIX,
        PATH_ECHO_PREFIX,
    ]
    .iter()
    .any(|prefix| response.starts_with(prefix))
}

pub fn workers_request(password: &str, desired_count: usize) -> String {
    format!("GETWORKERS:{password}|{desired_count}")
}

pub fn parse_tunworkers_response(payload: &[u8]) -> Option<(usize, usize)> {
    let text = std::str::from_utf8(payload).ok()?;
    if let Some(rest) = text.strip_prefix("TUNWORKERS:") {
        let mut parts = rest.split(':');
        let agreed = parts.next()?.trim().parse::<usize>().ok()?;
        let server_limit = parts
            .next()
            .and_then(|v| v.trim().parse::<usize>().ok())
            .unwrap_or(0);
        return Some((agreed, server_limit));
    }
    if let Some(rest) = text.strip_prefix("WORKERS:") {
        let limit = rest.trim().parse::<usize>().ok()?;
        return Some((limit, limit));
    }
    None
}

pub fn is_panel_restart_notice(response: &[u8]) -> bool {
    response == PANEL_RESTART_NOTICE
}

/// Распознаёт ли пакет сигнал «правило изменилось». Сравнение полное, как у
/// `is_panel_restart_notice`: совпадение по префиксу превратило бы любой
/// неизвестный бинарь с тем же началом в сигнал и вызвало бы лишний `GETCONF`.
pub fn is_routing_changed_notice(response: &[u8]) -> bool {
    response == ROUTING_CHANGED_NOTICE
}

pub fn disconnect_request(password: &str, salt: &str) -> String {
    format!("DISCONNECT:{password}|{salt}")
}

pub fn parse_stream_repair(payload: &[u8]) -> Option<StreamRepairCommand> {
    parse_stream_command(payload, STREAM_REPAIR_PREFIX)
}

pub fn parse_stream_alive(payload: &[u8]) -> Option<StreamRepairCommand> {
    parse_stream_command(payload, STREAM_ALIVE_PREFIX)
}

fn parse_stream_command(payload: &[u8], prefix: &[u8]) -> Option<StreamRepairCommand> {
    let rest = payload.strip_prefix(prefix)?;
    if rest.len() < 11 {
        return None;
    }
    let sequence = u64::from_be_bytes(rest[0..8].try_into().ok()?);
    let desired_count = u16::from_be_bytes(rest[8..10].try_into().ok()?);
    let count = usize::from(rest[10]);
    let ids = &rest[11..];
    if sequence == 0
        || desired_count == 0
        || desired_count > MAX_STREAM_WORKERS
        || ids.len() != count.saturating_mul(2)
    {
        return None;
    }
    let mut worker_ids = Vec::with_capacity(count);
    for chunk in ids.chunks_exact(2) {
        let worker_id = u16::from_be_bytes(chunk.try_into().ok()?);
        if worker_id == 0 || worker_id > desired_count {
            return None;
        }
        worker_ids.push(worker_id);
    }
    (!worker_ids.is_empty()).then_some(StreamRepairCommand {
        sequence,
        desired_count,
        worker_ids,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_matches_go_contract() {
        let req1 = config_request("9000", "pass1234567890ab", 7, "salt", 4, None, false, None);
        assert_eq!(req1, "GETCONF:9000|pass1234567890ab|7|salt|4|");

        let req2 = config_request(
            "9000",
            "pass1234567890ab",
            7,
            "salt",
            4,
            Some(36),
            false,
            None,
        );
        assert_eq!(req2, "GETCONF:9000|pass1234567890ab|7|salt|4|36");
    }

    #[test]
    fn config_owner_marks_its_request() {
        let owner = config_request("9000", "pass", 7, "salt", 1, Some(10), true, None);
        assert_eq!(owner, "GETCONF:9000|pass|7|salt|1|10|owner");

        let worker = config_request("9000", "pass", 7, "salt", 2, Some(10), false, None);
        assert_eq!(worker, "GETCONF:9000|pass|7|salt|2|10");
    }

    #[test]
    fn owner_with_a_cached_sha_appends_an_eighth_field() {
        let sha = "5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6";
        assert_eq!(
            config_request("9000", "pass", 7, "salt", 4, Some(10), true, Some(sha)),
            format!("GETCONF:9000|pass|7|salt|4|10|owner|{sha}")
        );
        assert_eq!(
            config_request("9000", "pass", 7, "salt", 4, Some(10), true, None),
            "GETCONF:9000|pass|7|salt|4|10|owner"
        );
        assert_eq!(
            config_request("9000", "pass", 7, "salt", 4, Some(10), false, Some(sha)),
            "GETCONF:9000|pass|7|salt|4|10"
        );
    }

    #[test]
    fn owner_with_cached_content_appends_a_ninth_field() {
        let ips = "5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6";
        let content = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                4,
                Some(10),
                true,
                Some(ips),
                Some(content),
                false
            ),
            format!("GETCONF:9000|pass|7|salt|4|10|owner|{ips}|{content}")
        );
        // Без ips-кеша восьмое поле остаётся пустым, чтобы девятое не сдвинулось.
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                4,
                Some(10),
                true,
                None,
                Some(content),
                false
            ),
            format!("GETCONF:9000|pass|7|salt|4|10|owner||{content}")
        );
        // Не-owner контент не шлёт.
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                4,
                Some(10),
                false,
                None,
                Some(content),
                false
            ),
            "GETCONF:9000|pass|7|salt|4|10"
        );
    }

    #[test]
    fn routing2_capability_is_advertised_for_owner_and_worker() {
        let ips = "5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6";
        let content = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                4,
                Some(10),
                true,
                Some(ips),
                Some(content),
                true
            ),
            format!("GETCONF:9000|pass|7|salt|4|10|owner|{ips}|{content}|routing2")
        );
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                4,
                Some(10),
                true,
                None,
                None,
                true
            ),
            "GETCONF:9000|pass|7|salt|4|10|owner|||routing2"
        );
        assert_eq!(
            config_request_with_content(
                "9000",
                "pass",
                7,
                "salt",
                2,
                Some(10),
                false,
                None,
                None,
                true
            ),
            "GETCONF:9000|pass|7|salt|2|10|routing2"
        );
    }

    #[test]
    fn routing_delivery_prefix_accepts_both_formats() {
        assert!(is_routing_delivery(b"ROUTING:START:3"));
        assert!(is_routing_delivery(b"ROUTING2:START:0000000000000001:3"));
        assert!(!is_routing_delivery(b"ROUTING_ABSENT"));
        assert!(!is_routing_delivery(b"TUNCONF:x"));
    }

    #[test]
    fn content_sha_is_read_from_a_live_file() {
        let path = std::env::temp_dir().join(format!(
            "csqtt-content-sha-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or_default()
        ));
        let sha = "a".repeat(64);
        std::fs::write(&path, &sha).expect("write sha file");
        assert_eq!(
            read_routing_content_sha(&path).as_deref(),
            Some(sha.as_str())
        );
        std::fs::write(&path, "not-a-sha").expect("write bad sha");
        assert_eq!(read_routing_content_sha(&path), None);
        std::fs::remove_file(&path).expect("remove sha file");
        assert_eq!(read_routing_content_sha(&path), None);
    }

    #[test]
    fn malformed_sha_is_dropped_instead_of_sent() {
        assert_eq!(parse_routing_ips_sha("not-a-sha"), None);
        assert_eq!(
            parse_routing_ips_sha(
                "5CF0B8862AD4F3318831DCF2E94076E221320FF47D77F1A12EBE661F613F70F6"
            )
            .map(|value| value.len()),
            Some(64)
        );
        assert_eq!(
            parse_routing_ips_sha(
                "5CF0B8862AD4F3318831DCF2E94076E221320FF47D77F1A12EBE661F613F70F6"
            ),
            Some("5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6".to_owned())
        );
    }

    #[test]
    fn response_matches_go_contract() {
        assert_eq!(
            parse_config_response(b"TUNCONF:10.66.66.2:1.1.1.1").unwrap(),
            ConfigResponse::Config("TUNCONF:10.66.66.2:1.1.1.1".into())
        );
        assert!(
            parse_config_response(b"DENIED:wrong_password")
                .unwrap_err()
                .to_string()
                .contains("FATAL_AUTH")
        );
        assert!(
            parse_config_response(b"DENIED:protocol_mismatch")
                .unwrap_err()
                .to_string()
                .contains("FATAL_PROTOCOL")
        );
    }

    #[test]
    fn control_responses_never_enter_tun() {
        for value in [
            b"TUNCONF:10.66.67.3:1.1.1.1".as_slice(),
            b"NOCONF".as_slice(),
            b"DENIED:expired".as_slice(),
            b"READY_OK".as_slice(),
            b"OK:disconnected".as_slice(),
            b"TUNWORKERS:20:20".as_slice(),
            b"WORKERS:20".as_slice(),
            PANEL_RESTART_NOTICE,
            STREAM_REPAIR_PREFIX,
            STREAM_ALIVE_PREFIX,
        ] {
            assert!(is_control_response(value));
        }
        assert!(!is_control_response(&[0x45, 0, 0, 20]));
    }

    #[test]
    fn parses_tunworkers_response() {
        assert_eq!(
            parse_tunworkers_response(b"TUNWORKERS:20:20"),
            Some((20, 20))
        );
        assert_eq!(parse_tunworkers_response(b"TUNWORKERS:44:0"), Some((44, 0)));
        assert_eq!(parse_tunworkers_response(b"WORKERS:15"), Some((15, 15)));
        assert_eq!(parse_tunworkers_response(b"TUNCONF:10.0.0.1"), None);
    }

    #[test]
    fn panel_restart_notice_requires_an_exact_match() {
        assert!(is_panel_restart_notice(PANEL_RESTART_NOTICE));
        assert!(!is_panel_restart_notice(b"CSQTT_PANEL_RESTART_V1"));
        let mut modified = PANEL_RESTART_NOTICE.to_vec();
        modified[1] ^= 1;
        assert!(!is_panel_restart_notice(&modified));
    }

    /// Сигнал «правило изменилось» обязан распознаваться строго и не должен
    /// путаться с соседями: распознавание `ROUTING:`-чанка как сигнала
    /// обрывало бы сборку правила, а распознавание уведомления о перезапуске
    /// панели — вызывало лишнюю пересборку туннеля.
    #[test]
    fn routing_changed_notice_requires_an_exact_match_and_is_unique() {
        assert!(is_routing_changed_notice(ROUTING_CHANGED_NOTICE));
        assert!(!is_routing_changed_notice(b"CSQTT_ROUTING_CHANGED_V1"));
        // Только префикс — не сигнал.
        assert!(!is_routing_changed_notice(
            b"\xffCSQTT_ROUTING_CHANGED_V1\x00"
        ));
        let mut modified = ROUTING_CHANGED_NOTICE.to_vec();
        modified[1] ^= 1;
        assert!(!is_routing_changed_notice(&modified));
        let mut tail = ROUTING_CHANGED_NOTICE.to_vec();
        let last = tail.len() - 1;
        tail[last] ^= 1;
        assert!(!is_routing_changed_notice(&tail));

        // Отличим от соседей по протоколу.
        assert_ne!(ROUTING_CHANGED_NOTICE, PANEL_RESTART_NOTICE);
        assert!(!is_panel_restart_notice(ROUTING_CHANGED_NOTICE));
        assert!(!ROUTING_CHANGED_NOTICE.starts_with(b"ROUTING:"));
        assert!(!is_routing_changed_notice(b"ROUTING:ABSENT"));
        assert!(!is_routing_changed_notice(
            b"ROUTING:1:46:YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4"
        ));
    }

    /// Notice обязан считаться управляющим пакетом: иначе `reader_loop`
    /// относит его к «отброшенным не-IP пакетам», и счётчик потерь показывает
    /// проблему там, где её нет.
    #[test]
    fn routing_changed_notice_is_a_control_packet() {
        assert!(is_control_response(ROUTING_CHANGED_NOTICE));
        assert!(!is_config_response(ROUTING_CHANGED_NOTICE));
    }

    #[test]
    fn config_wait_ignores_tunneled_packets_and_other_controls() {
        assert!(is_config_response(b"TUNCONF:10.66.67.3:1.1.1.1"));
        assert!(is_config_response(b"NOCONF"));
        assert!(is_config_response(b"DENIED:expired"));
        assert!(!is_config_response(b"READY_OK"));
        assert!(!is_config_response(&[0x45, 0, 0, 20]));
        assert!(!is_config_response(&[0xff, 0xfe]));
    }

    #[test]
    fn parses_stream_repair_command() {
        let mut payload = STREAM_REPAIR_PREFIX.to_vec();
        payload.extend_from_slice(&9u64.to_be_bytes());
        payload.extend_from_slice(&36u16.to_be_bytes());
        payload.push(2);
        payload.extend_from_slice(&14u16.to_be_bytes());
        payload.extend_from_slice(&28u16.to_be_bytes());
        assert_eq!(
            parse_stream_repair(&payload),
            Some(StreamRepairCommand {
                sequence: 9,
                desired_count: 36,
                worker_ids: vec![14, 28],
            })
        );
        assert!(parse_stream_alive(&payload).is_none());
        payload[STREAM_REPAIR_PREFIX.len() + 10] = 0;
        assert!(parse_stream_repair(&payload).is_none());
    }

    #[test]
    fn malformed_utf8_returns_error() {
        assert!(parse_config_response(&[0xff, 0xfe]).is_err());
    }

    #[test]
    fn no_config_response_is_preserved() {
        assert_eq!(
            parse_config_response(b"NOCONF").unwrap(),
            ConfigResponse::NoConfig
        );
    }

    #[test]
    fn auth_denied_reasons_distinguish_fatal_from_retryable() {
        for response in [
            b"DENIED:wrong_password".as_slice(),
            b"DENIED:expired".as_slice(),
            b"DENIED:deactivated".as_slice(),
        ] {
            assert!(
                parse_config_response(response)
                    .unwrap_err()
                    .to_string()
                    .contains("FATAL_AUTH")
            );
        }
        for response in [
            b"DENIED:invalid_epoch".as_slice(),
            b"DENIED:invalid_worker".as_slice(),
            b"DENIED:server_busy".as_slice(),
            b"DENIED:unknown".as_slice(),
        ] {
            let error = parse_config_response(response).unwrap_err().to_string();
            assert!(!error.contains("FATAL_AUTH"));
            assert!(!error.contains("FATAL_PROTOCOL"));
        }
    }

    #[test]
    fn test_two_stage_handshake_requests_and_responses() {
        let req1 = config_request("45000", "pass123", 789, "salt99", 1, None, false, None);
        assert_eq!(req1, "GETCONF:45000|pass123|789|salt99|1|");

        let req2 = workers_request("pass123", 25);
        assert_eq!(req2, "GETWORKERS:pass123|25");

        let res1 = parse_tunworkers_response(b"TUNWORKERS:10:10");
        assert_eq!(res1, Some((10, 10)));

        let res2 = parse_tunworkers_response(b"TUNWORKERS:25:0");
        assert_eq!(res2, Some((25, 0)));

        let res_legacy = parse_tunworkers_response(b"WORKERS:15");
        assert_eq!(res_legacy, Some((15, 15)));

        assert!(is_control_response(b"TUNWORKERS:25:0"));
        assert!(is_control_response(b"TUNCONF:test"));
    }
}
