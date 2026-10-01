#!/usr/bin/env bash
# Sets up the rust-8051 proof of concept toolchain:
#   - SDCC (8051 C compiler, includes the s51 simulator)
#   - a Rust nightly that rustc_codegen_clr builds with
#   - rustc_codegen_clr (Rust -> C backend) in third_party/
#   - llvm-cbe (LLVM IR -> C) in third_party/, built against the system LLVM
# Everything this script installs is recorded in .installed so uninstall.sh can remove it again.
#
# Tested target: Linux x86_64 (what rustc_codegen_clr is tested on). macOS may work.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TP="$ROOT/third_party"
CLR="$TP/rustc_codegen_clr"
# Last commit of rustc_codegen_clr when this project was started (2025-10-14).
# It only builds with a narrow range of nightlies, so try the ones around that date.
CLR_REPO=https://github.com/FractalFir/rustc_codegen_clr
CLR_COMMIT=a9aa553
NIGHTLIES="nightly-2025-10-14 nightly-2025-10-15 nightly-2025-10-13 nightly-2025-10-12 nightly-2025-10-10 nightly-2025-10-07 nightly-2025-10-01"
INSTALLED="$ROOT/.installed"

log() { printf '\n==> %s\n' "$*"; }
record() { echo "$1" >> "$INSTALLED"; }
touch "$INSTALLED"

log "SDCC"
if command -v sdcc >/dev/null; then
	echo "already installed: $(sdcc --version | head -1)"
elif [ "$(uname)" = Darwin ]; then
	had_gputils=0
	brew list gputils >/dev/null 2>&1 && had_gputils=1
	brew install sdcc
	record "brew:sdcc"
	[ $had_gputils = 1 ] || record "brew:gputils"
elif command -v apt-get >/dev/null; then
	sudo apt-get update && sudo apt-get install -y sdcc sdcc-ucsim
	record "apt:sdcc"
	record "apt:sdcc-ucsim"
	echo "NOTE: RTLPlayground itself needs SDCC >= 4.5; distro packages may be older (fine for the PoC)."
elif command -v pacman >/dev/null; then
	# s51 is checked below; if missing, install ucsim separately
	sudo pacman -S --needed --noconfirm sdcc
	record "pacman:sdcc"
else
	echo "Install SDCC manually (https://sdcc.sourceforge.net) and re-run." >&2
	exit 1
fi
command -v s51 >/dev/null || echo "WARNING: s51 simulator not found; on Debian/Ubuntu it is in package sdcc-ucsim."

log "rustup"
command -v rustup >/dev/null || { echo "Install rustup first: https://rustup.rs" >&2; exit 1; }

log "rustc_codegen_clr @ $CLR_COMMIT"
mkdir -p "$TP"
if [ ! -d "$CLR/.git" ]; then
	git clone -q "$CLR_REPO" "$CLR"
fi
git -C "$CLR" checkout -q "$CLR_COMMIT"
# Local fixes, see patches/: accept the "custom" ABI of naked functions in compiler_builtins
for p in "$ROOT"/patches/rustc_codegen_clr-*.patch; do
	git -C "$CLR" apply --check "$p" 2>/dev/null && git -C "$CLR" apply "$p"
done

log "Finding a nightly that builds rustc_codegen_clr"
TC=""
for n in $NIGHTLIES; do
	echo "--- trying $n"
	if ! rustup toolchain list | grep -q "^$n"; then
		rustup toolchain install --profile minimal -c rust-src -c rustc-dev -c llvm-tools-preview "$n"
		record "rustup:$n"
	fi
	# The backend library plus the linker from the cilly crate, which env.sh points at
	if (cd "$CLR" && cargo "+$n" build --release 2>&1 | tail -3 && cargo "+$n" build --release -p cilly --bin linker 2>&1 | tail -3); then
		if [ -e "$CLR/target/release/linker" ] && { [ -e "$CLR/target/release/librustc_codegen_clr.so" ] || [ -e "$CLR/target/release/librustc_codegen_clr.dylib" ]; }; then
			TC="$n"
			break
		fi
	fi
done
[ -n "$TC" ] || { echo "No candidate nightly built rustc_codegen_clr; try other dates near $CLR_COMMIT's commit date." >&2; exit 1; }
echo "$TC" > "$ROOT/rust-toolchain.pinned"

LIB="$CLR/target/release/librustc_codegen_clr.so"
[ -e "$LIB" ] || LIB="$CLR/target/release/librustc_codegen_clr.dylib"
cat > "$ROOT/env.sh" <<EOF
# source this file to compile crates to C with rustc_codegen_clr
export RUSTUP_TOOLCHAIN=$TC
export C_MODE=1
export ASCII_IDENTS=1
export RUSTFLAGS="-Z codegen-backend=$LIB -C linker=$CLR/target/release/linker -C link-args=--cargo-support"
EOF

log "llvm-cbe (alternative route: LLVM IR -> C)"
CBE="$TP/llvm-cbe"
if ! command -v llvm-config >/dev/null; then
	echo "WARNING: llvm-config not found, skipping llvm-cbe (needs the system LLVM with headers)."
else
	[ -d "$CBE/.git" ] || git clone -q https://github.com/JuliaHubOSS/llvm-cbe "$CBE"
	# cmake and ninja go into a venv under third_party/ if they are not installed
	if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
		[ -x "$TP/venv/bin/cmake" ] || { python3 -m venv "$TP/venv" && "$TP/venv/bin/pip" -q install cmake ninja; }
		export PATH="$TP/venv/bin:$PATH"
	fi
	if (cmake -S "$CBE" -B "$CBE/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null && ninja -C "$CBE/build" llvm-cbe | tail -1); then
		echo "export LLVM_CBE=$CBE/build/tools/llvm-cbe/llvm-cbe" >> "$ROOT/env.sh"
	else
		echo "WARNING: llvm-cbe did not build; llvm-cbe's CMakeLists.txt names the LLVM version it needs ($(llvm-config --version) here)."
	fi
fi

log "Done"
echo "Toolchain: $TC (in rust-toolchain.pinned)"
echo "Use:       source $ROOT/env.sh"
echo "Remove:    $ROOT/uninstall.sh"
