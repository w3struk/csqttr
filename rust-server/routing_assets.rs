use anyhow::{Context, Result, bail};
use base64::Engine as _;
use flate2::Compression;
use flate2::write::GzEncoder;
use sha2::{Digest, Sha256};
use std::io::Write as _;
use std::net::Ipv4Addr;
use std::sync::LazyLock;

pub struct IpsAsset {
    pub text: String,
    pub sha256: String,
    pub blob_base64_gzip: String,
    #[allow(dead_code)] // число записей нужно тестам и диагностике
    pub count: usize,
}

pub struct RoutingAssets {
    pub domains: Vec<String>,
    pub domains_text: String,
    pub ips: IpsAsset,
}

/// Фиксированные списки маршрутизации, скомпилированные в сервер.
///
/// Инициализация намеренно паникует на невалидном ассете: сервер обязан
/// отказаться стартовать, а не отдавать клиенту усечённый или пустой список.
pub static ASSETS: LazyLock<RoutingAssets> = LazyLock::new(|| {
    parse_assets(
        include_str!("data/domains_ru.txt"),
        include_str!("data/ips_ru.txt"),
    )
    .unwrap_or_else(|error| panic!("invalid routing assets: {error:#}"))
});

pub fn parse_assets(domains_raw: &str, ips_raw: &str) -> Result<RoutingAssets> {
    let (domains, domains_text) = normalize_domains(domains_raw)?;
    let (ips_text, sha256, count) = normalize_ips(ips_raw)?;
    let blob_base64_gzip = gzip_base64(&ips_text)?;
    Ok(RoutingAssets {
        domains,
        domains_text,
        ips: IpsAsset {
            text: ips_text,
            sha256,
            blob_base64_gzip,
            count,
        },
    })
}

fn normalize_domains(raw: &str) -> Result<(Vec<String>, String)> {
    let mut domains = Vec::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let without_prefix = trimmed
            .strip_prefix("domain:")
            .map(str::trim)
            .unwrap_or(trimmed);
        let domain = without_prefix.trim().to_ascii_lowercase();
        let domain = domain.trim_end_matches('.');
        if domain.is_empty() {
            bail!("пустая запись домена: {line:?}");
        }
        if domain.chars().any(char::is_whitespace) || domain.contains('/') || domain.contains(':') {
            bail!("некорректная запись домена: {line:?}");
        }
        domains.push(domain.to_owned());
    }
    domains.sort_unstable();
    domains.dedup();
    let mut text = String::with_capacity(domains.iter().map(|d| d.len() + 1).sum());
    for domain in &domains {
        text.push_str(domain);
        text.push('\n');
    }
    Ok((domains, text))
}

fn normalize_ips(raw: &str) -> Result<(String, String, usize)> {
    let mut entries: Vec<(u32, u8)> = Vec::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some(cidr) = parse_cidr(trimmed) else {
            bail!("некорректная запись адреса: {line:?}");
        };
        entries.push(cidr);
    }
    entries.sort_unstable();
    entries.dedup();
    let mut text = String::with_capacity(entries.len() * 16);
    for (network, prefix) in &entries {
        text.push_str(&format!("{}/{prefix}\n", Ipv4Addr::from(*network)));
    }
    let sha256 = hex::encode(Sha256::digest(text.as_bytes()));
    Ok((text, sha256, entries.len()))
}

fn parse_cidr(line: &str) -> Option<(u32, u8)> {
    let (address, prefix) = line.split_once('/')?;
    if prefix.contains('/') {
        return None;
    }
    let address: Ipv4Addr = address.parse().ok()?;
    let prefix: u8 = prefix.parse().ok()?;
    if prefix > 32 {
        return None;
    }
    Some((u32::from(address), prefix))
}

fn gzip_base64(text: &str) -> Result<String> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::best());
    encoder
        .write_all(text.as_bytes())
        .context("не удалось сжать список адресов")?;
    let compressed = encoder
        .finish()
        .context("не удалось сжать список адресов")?;
    Ok(base64::engine::general_purpose::STANDARD.encode(compressed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_assets_keep_their_shape() {
        let assets = parse_assets(
            include_str!("data/domains_ru.txt"),
            include_str!("data/ips_ru.txt"),
        )
        .unwrap();
        assert_eq!(assets.domains.len(), 515);
        assert_eq!(assets.domains_text.len(), 5_967);
        assert_eq!(assets.ips.count, 6_710);
        assert_eq!(assets.ips.text.len(), 115_173);
        assert_eq!(
            assets.ips.sha256,
            "5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6"
        );
    }

    #[test]
    fn domains_are_sorted_deduplicated_and_lf_terminated() {
        let (domains, text) =
            normalize_domains("# comment\nok.ru\ndomain:Example.COM.\nok.ru\n\n  vk.com  \n")
                .unwrap();
        assert_eq!(domains, vec!["example.com", "ok.ru", "vk.com"]);
        assert_eq!(text, "example.com\nok.ru\nvk.com\n");
        assert!(text.ends_with('\n'));
        assert!(!text.contains("domain:"));
    }

    #[test]
    fn ips_are_sorted_by_numeric_network_value() {
        let assets = parse_assets("ok.ru\n", include_str!("data/ips_ru.txt")).unwrap();
        let mut lines = assets.ips.text.lines();
        assert_eq!(lines.next(), Some("5.8.43.1/32"));
        assert_eq!(lines.next_back(), Some("217.195.219.254/32"));
        let mut previous = None;
        for line in assets.ips.text.lines() {
            let (network, prefix) = parse_cidr(line).unwrap();
            if let Some(prev) = previous {
                assert!(prev < (network, prefix), "not sorted at {line}");
            }
            previous = Some((network, prefix));
        }
    }

    #[test]
    fn garbage_line_is_a_startup_error_not_a_skip() {
        assert!(parse_assets("ok.ru\nfoo bar\n", "5.8.43.1/32\n").is_err());
        assert!(parse_assets("ok.ru\n", "5.8.43.1/32\n::1/128\n").is_err());
        assert!(parse_assets("ok.ru\n", "5.8.43.1/33\n").is_err());
    }

    #[test]
    fn blob_is_gzip_of_the_normalized_text() {
        let assets = parse_assets("ok.ru\n", "5.8.43.1/32\n").unwrap();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&assets.ips.blob_base64_gzip)
            .unwrap();
        let text =
            std::io::read_to_string(flate2::read::GzDecoder::new(decoded.as_slice())).unwrap();
        assert_eq!(text, assets.ips.text);
        assert_eq!(
            assets.ips.sha256,
            hex::encode(Sha256::digest(text.as_bytes()))
        );
    }

    #[test]
    fn pinned_blob_stays_inside_the_event_budget() {
        assert!(ASSETS.ips.blob_base64_gzip.len() <= 27_000);
        assert!(ASSETS.ips.blob_base64_gzip.len().div_ceil(650) <= 42);
    }
}
