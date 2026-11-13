#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Фикстура scripts/check_versions.sh: собирает минимальное дерево во
# временном каталоге (в рабочее дерево не пишет) и проверяет, что
# расхождение версии обнаруживается и называет отставшее место.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check_versions.sh"

if [[ ! -f "$CHECKER" ]]; then
    echo "fixture: не найден $CHECKER" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

write_fixture() {
    local root="$1"
    mkdir -p "$root/app" "$root/rust-client" "$root/rust-server" "$root/scripts"

    cat >"$root/app/build.gradle.kts" <<'EOF'
android {
    defaultConfig {
        versionCode = 232
        versionName = "2.5.2" +
            (providers.gradleProperty("csqtt.versionSuffix").orNull ?: "")
    }
}
EOF

    cat >"$root/rust-client/Cargo.toml" <<'EOF'
[package]
name = "csqtt-client"
version = "2.5.2"
EOF

    cat >"$root/rust-client/Cargo.lock" <<'EOF'
version = 4

[[package]]
name = "csqtt-client"
version = "2.5.2"
dependencies = []
EOF

    cat >"$root/rust-server/Cargo.toml" <<'EOF'
[package]
name = "csqtt"
version = "2.5.2"
EOF

    cat >"$root/rust-server/Cargo.lock" <<'EOF'
version = 4

[[package]]
name = "csqtt"
version = "2.5.2"
dependencies = []
EOF

    cat >"$root/scripts/install.sh" <<'EOF'
#!/bin/bash
readonly SCRIPT_VERSION="2.5.2"
readonly CSQTT_DOCKER_IMAGE="csqtt:2.5.2"
EOF

    cat >"$root/rust-server/main.rs" <<'EOF'
fn banner() {
    log_event(&app, "INFO", "SYSTEM", " reCSQTT Server 2.5.2");
}
EOF

    cat >"$root/rust-server/web_panel.rs" <<'EOF'
const PWA_SERVICE_WORKER: &str = r##"const CACHE_NAME = 'csqtt-panel-shell-2.5.2-pwa5';
"##;
EOF
}

fail() {
    echo "FAIL fixture: $*" >&2
    exit 1
}

# expect_failure_naming <описание> <фрагмент пути>
# Проверяет, что checker падает и в stderr называет конкретное место.
expect_failure_naming() {
    local label="$1" path_fragment="$2"
    local stderr_file="$TMP_ROOT/stderr.txt"
    if bash "$CHECKER" --root "$TMP_ROOT" >/dev/null 2>"$stderr_file"; then
        fail "$label: проверка обязана упасть"
    fi
    if ! grep -Fq -- "$path_fragment" "$stderr_file"; then
        echo "--- stderr ---" >&2
        cat "$stderr_file" >&2
        fail "$label: сообщение не указывает на $path_fragment"
    fi
}

write_fixture "$TMP_ROOT"

# 1. Все места совпадают: чистый прогон.
if ! bash "$CHECKER" --root "$TMP_ROOT" >/dev/null; then
    fail "чистое дерево должно проходить (exit 0)"
fi

# 2. Порча SCRIPT_VERSION: exit != 0 и сообщение называет scripts/install.sh.
sed -i 's/SCRIPT_VERSION="2\.5\.2"/SCRIPT_VERSION="2.5.1"/' "$TMP_ROOT/scripts/install.sh"
stderr_file="$TMP_ROOT/stderr.txt"
if bash "$CHECKER" --root "$TMP_ROOT" >/dev/null 2>"$stderr_file"; then
    fail "отставший SCRIPT_VERSION должен валить проверку"
fi
if ! grep -q 'scripts/install.sh' "$stderr_file"; then
    echo "--- stderr ---" >&2
    cat "$stderr_file" >&2
    fail "сообщение не указывает на scripts/install.sh"
fi

# 3. Восстановленное дерево с совпадающим тегом.
sed -i 's/SCRIPT_VERSION="2\.5\.1"/SCRIPT_VERSION="2.5.2"/' "$TMP_ROOT/scripts/install.sh"
if ! bash "$CHECKER" --root "$TMP_ROOT" --tag v2.5.2 >/dev/null; then
    fail "--tag v2.5.2 должен проходить"
fi

# 4. Чужой тег: exit != 0.
if bash "$CHECKER" --root "$TMP_ROOT" --tag v2.5.1 >/dev/null 2>&1; then
    fail "--tag v2.5.1 должен валить проверку"
fi

# 5. Отсутствующий файл: exit != 0 и сообщение называет путь.
write_fixture "$TMP_ROOT"
rm -f "$TMP_ROOT/rust-client/Cargo.lock"
expect_failure_naming "отсутствующий rust-client/Cargo.lock" "rust-client/Cargo.lock"

# 6. Расхождение версии в Cargo.lock сервера.
write_fixture "$TMP_ROOT"
sed -i 's/^version = "2\.5\.2"$/version = "2.5.1"/' "$TMP_ROOT/rust-server/Cargo.lock"
expect_failure_naming "Cargo.lock rust-server с чужой версией" "rust-server/Cargo.lock"

# 7. Расхождение баннера в main.rs.
write_fixture "$TMP_ROOT"
sed -i 's/reCSQTT Server 2\.5\.2/reCSQTT Server 2.5.1/' "$TMP_ROOT/rust-server/main.rs"
expect_failure_naming "баннер main.rs с чужой версией" "rust-server/main.rs"

# 8. Расхождение CACHE_NAME в web_panel.rs.
write_fixture "$TMP_ROOT"
sed -i 's/csqtt-panel-shell-2\.5\.2-pwa5/csqtt-panel-shell-2.5.1-pwa5/' \
    "$TMP_ROOT/rust-server/web_panel.rs"
expect_failure_naming "CACHE_NAME web_panel.rs с чужой версией" "rust-server/web_panel.rs"

echo "check_versions fixture: OK"
