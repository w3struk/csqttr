#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -euo pipefail

RUST_CLIENT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$RUST_CLIENT_DIR"

cargo clippy --bin client -- \
    -D clippy::unwrap_used \
    -D clippy::expect_used \
    -D clippy::panic \
    -D clippy::unreachable \
    -D clippy::todo \
    -D clippy::unimplemented

echo "Runtime panic lint passed"
