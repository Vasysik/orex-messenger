#!/usr/bin/env bash
# Собирает wasm-биндинги vodozemac и кладёт их в web/pkg/,
# чтобы сквозное шифрование работало в браузере.
#
# Требования: Rust toolchain (rustup) + cargo.
# Версия должна совпадать с flutter_vodozemac в pubspec.yaml.
set -e

VERSION="0.5.0"   # <-- держите в синхроне с pubspec (flutter_vodozemac: ^0.5.0)

echo "[orex] Building vodozemac wasm v$VERSION ..."
rm -rf .vodozemac
git clone https://github.com/famedly/dart-vodozemac.git -b "$VERSION" .vodozemac
cd .vodozemac
cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen build-web --dart-root dart --rust-root "$(pwd)/rust" --release
cd ..
mkdir -p web
rm -rf web/pkg
mv .vodozemac/dart/web/pkg web/
rm -rf .vodozemac
echo "[orex] Done. web/pkg now contains vodozemac_bindings_dart.js + .wasm"
