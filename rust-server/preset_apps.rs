use serde::Serialize;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PresetEntry {
    pub package: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PresetApps {
    pub red: Vec<PresetEntry>,
    pub orange: Vec<PresetEntry>,
}

pub const PRESET_JSON: &str = include_str!("ru_apps_preset.json");

static PRESET: LazyLock<PresetApps> = LazyLock::new(|| parse_preset(PRESET_JSON));

pub fn preset_apps() -> &'static PresetApps {
    &PRESET
}

#[allow(dead_code)]
pub fn red_packages() -> Vec<String> {
    preset_apps()
        .red
        .iter()
        .map(|entry| entry.package.clone())
        .collect()
}

#[allow(dead_code)]
pub fn orange_packages() -> Vec<String> {
    preset_apps()
        .orange
        .iter()
        .map(|entry| entry.package.clone())
        .collect()
}

fn parse_preset(json: &str) -> PresetApps {
    let value = match serde_json::from_str::<serde_json::Value>(json) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("[preset] файл пресета не разобран: {error}");
            return PresetApps {
                red: Vec::new(),
                orange: Vec::new(),
            };
        }
    };
    let Some(object) = value.as_object() else {
        eprintln!("[preset] файл пресета не разобран: ожидался объект");
        return PresetApps {
            red: Vec::new(),
            orange: Vec::new(),
        };
    };
    PresetApps {
        red: parse_entries(object.get("red")),
        orange: parse_entries(object.get("orange")),
    }
}

fn parse_entries(value: Option<&serde_json::Value>) -> Vec<PresetEntry> {
    let Some(entries) = value.and_then(serde_json::Value::as_array) else {
        return Vec::new();
    };
    let mut parsed = Vec::with_capacity(entries.len());
    for entry in entries {
        match parse_entry(entry) {
            Some(parsed_entry) => parsed.push(parsed_entry),
            None => eprintln!("[preset] пропущена запись: {entry}"),
        }
    }
    parsed
}

fn parse_entry(entry: &serde_json::Value) -> Option<PresetEntry> {
    match entry {
        serde_json::Value::String(package) => valid_package_name(package).then(|| PresetEntry {
            package: package.clone(),
            name: String::new(),
        }),
        serde_json::Value::Object(object) => {
            let package = object.get("package")?.as_str()?;
            if !valid_package_name(package) {
                return None;
            }
            let name = object
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_string();
            Some(PresetEntry {
                package: package.to_string(),
                name,
            })
        }
        _ => None,
    }
}

fn valid_package_name(value: &str) -> bool {
    if !(1..=255).contains(&value.len()) {
        return false;
    }
    value.split('.').all(|segment| {
        let mut chars = segment.chars();
        match chars.next() {
            Some(first) if first.is_ascii_alphabetic() || first == '_' => {
                chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
            }
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_string_entry_is_parsed() {
        let preset = parse_preset(r#"{"red":["com.a"],"orange":[]}"#);
        assert_eq!(
            preset.red,
            vec![PresetEntry {
                package: "com.a".into(),
                name: String::new(),
            }]
        );
    }

    #[test]
    fn object_entry_without_name_is_parsed() {
        let preset = parse_preset(r#"{"red":[{"package":"com.b"}]}"#);
        assert_eq!(preset.red.len(), 1);
        assert_eq!(preset.red[0].package, "com.b");
        assert!(preset.red[0].name.is_empty());
    }

    #[test]
    fn unknown_entry_fields_are_ignored() {
        let preset = parse_preset(r#"{"red":[{"package":"com.b","level":"weird","nested":{}}]}"#);
        assert_eq!(preset.red.len(), 1);
        assert_eq!(preset.red[0].package, "com.b");
    }

    #[test]
    fn invalid_package_name_is_skipped_without_panicking() {
        let preset = parse_preset(r#"{"red":["bad pkg","com..x"],"orange":["com.ok"]}"#);
        assert!(preset.red.is_empty());
        assert_eq!(
            preset.orange,
            vec![PresetEntry {
                package: "com.ok".into(),
                name: String::new(),
            }]
        );
    }

    #[test]
    fn unreadable_entry_is_skipped_without_panicking() {
        let preset = parse_preset(r#"{"red":[42,{"package":123}]}"#);
        assert!(preset.red.is_empty());
    }

    #[test]
    fn broken_json_yields_empty_preset_without_panicking() {
        assert_eq!(
            parse_preset("{{{"),
            PresetApps {
                red: Vec::new(),
                orange: Vec::new(),
            }
        );
    }

    #[test]
    fn missing_or_wrong_shaped_arrays_yield_empty_preset() {
        let empty = PresetApps {
            red: Vec::new(),
            orange: Vec::new(),
        };
        assert_eq!(parse_preset(""), empty);
        assert_eq!(parse_preset("{}"), empty.clone());
        assert_eq!(parse_preset(r#"{"red":{}}"#), empty);
    }

    #[test]
    fn package_name_validator_mirrors_kotlin_rules() {
        assert!(valid_package_name("android"));
        assert!(valid_package_name("com.example_app.client2"));
        assert!(!valid_package_name("com..example"));
        assert!(!valid_package_name("com.example app"));
        assert!(!valid_package_name(".com"));
        assert!(!valid_package_name("com.1bad"));
        assert!(!valid_package_name(&"a".repeat(256)));
    }

    #[test]
    fn shipped_preset_file_parses_entirely_with_valid_unique_packages() {
        let root: serde_json::Value = match serde_json::from_str(PRESET_JSON) {
            Ok(root) => root,
            Err(error) => panic!("shipped preset is not valid JSON: {error}"),
        };
        let mut seen = std::collections::HashSet::new();
        for key in ["red", "orange"] {
            let entries = match root.get(key).and_then(serde_json::Value::as_array) {
                Some(entries) => entries,
                None => panic!("shipped preset `{key}` is not an array"),
            };
            assert!(!entries.is_empty(), "shipped preset `{key}` is empty");
            for entry in entries {
                let package = match entry {
                    serde_json::Value::String(package) => package.as_str(),
                    serde_json::Value::Object(object) => {
                        match object.get("package").and_then(serde_json::Value::as_str) {
                            Some(package) if !package.is_empty() => package,
                            _ => panic!("shipped preset `{key}` entry has no package: {entry}"),
                        }
                    }
                    other => panic!("shipped preset `{key}` has an unreadable entry: {other}"),
                };
                assert!(
                    valid_package_name(package),
                    "shipped preset `{key}` has an invalid package: {package}"
                );
                assert!(
                    seen.insert(package),
                    "shipped preset has a duplicate package: {package}"
                );
            }
        }
    }

    #[test]
    fn sberbank_is_the_only_orange_entry() {
        assert_eq!(orange_packages(), vec!["ru.sberbankmobile".to_string()]);
    }
}
