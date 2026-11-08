#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Source this helper with REPO_ROOT set. Copy only build_input_files inputs,
# never a whole checkout, generated payloads, dist directories or Cargo caches.
make_server_root() {
    local root="$1" path prefix rel
    local -a inputs=(
        rust-server/build_linux.sh
        rust-server/build_linux_variants.sh
        rust-server/Cargo.toml
        rust-server/Cargo.lock
        rust-server/rust-toolchain.toml
        rust-server/ru_apps_preset.json
        rust-server/data/domains_ru.txt
        rust-server/data/ips_ru.txt
        scripts/server_asset_provenance.sh
    )

    for path in "$REPO_ROOT"/rust-server/*.rs "$REPO_ROOT"/rust-server/data/*.txt "$REPO_ROOT"/shared/*.rs; do
        [[ -f "$path" ]] || continue
        inputs+=("${path#"$REPO_ROOT/"}")
    done
    for prefix in .cargo rust-server/.cargo; do
        [[ -d "$REPO_ROOT/$prefix" ]] || continue
        while IFS= read -r -d '' path; do
            inputs+=("${path#"$REPO_ROOT/"}")
        done < <(find "$REPO_ROOT/$prefix" -type f -print0)
    done

    for rel in "${inputs[@]}"; do
        mkdir -p -- "$(dirname -- "$root/$rel")" || return
        cp -- "$REPO_ROOT/$rel" "$root/$rel" || return
    done
}

# Synthetic data for the real ELF/revision checks, not an executable server.
# e_machine occupies bytes 18-19 in little-endian order, including its high byte.
write_server_elf() {
    local path="$1" class="$2" machine="$3" wire_revision="$4"
    mkdir -p -- "$(dirname -- "$path")" || return
    {
        printf '\177ELF'
        printf '%b' "$(printf '\\%03o' "$class")"
        printf '\001\001'
        printf '\000%.0s' {1..9}
        printf '\002\000'
        printf '%b' "$(printf '\\%03o\\%03o' "$((machine & 255))" "$(((machine >> 8) & 255))")"
        printf '\000%.0s' {1..44}
        printf '\n%s\n' "$wire_revision"
    } >"$path"
}
