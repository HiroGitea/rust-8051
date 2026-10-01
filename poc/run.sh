#!/usr/bin/env bash
# Phase 0 PoC: CRC16 in Rust -> C -> SDCC (mcs51) -> s51, compared with hand-written C.
#   route clr: rustc_codegen_clr C mode (x86_64 target), the rs_crc16 function cut out of its output
#   route cbe: rustc --emit=llvm-ir for msp430-none-elf (16 bit usize/pointers) -> llvm-cbe -> cbe_fix.py
# Needs the toolchain from ../setup.sh. Outputs go to out/.
set -euo pipefail

POC="$(cd "$(dirname "$0")" && pwd)"
OUT="$POC/out"
SDCC_FLAGS="-mmcs51 --model-large --opt-code-size"
mkdir -p "$OUT"
# shellcheck source=/dev/null
source "$POC/../env.sh"

echo "==> clr: Rust -> C with rustc_codegen_clr"
(cd "$POC/crc16" && cargo build --release 2>&1 | grep -E '^error|Finished')
cp "$POC/crc16/target/x86_64-unknown-linux-gnu/release/deps/libcrc16.c" "$OUT/rs_full.c"
{
	echo '/* rs_crc16 extracted from the rustc_codegen_clr C output (rs_full.c), unchanged */'
	echo '#include <stdint.h>'
	awk '/^uint16_t rs_crc16\(.*\)\{$/{p=1} p{print} p&&/^}/{exit}' "$OUT/rs_full.c"
} > "$OUT/rs_crc16.c"

echo "==> cbe: Rust -> LLVM IR (msp430) -> C with llvm-cbe"
(cd "$POC/crc16-llvm" && env -u RUSTFLAGS -u C_MODE cargo rustc --release --target msp430-none-elf \
	-Zbuild-std=core -- --emit=llvm-ir 2>&1 | grep -E '^error|Finished')
LL=$(ls -t "$POC"/crc16-llvm/target/msp430-none-elf/release/deps/crc16-*.ll | head -1)
"$LLVM_CBE" "$LL" -o "$OUT/cbe_full.c"
"$POC/cbe_fix.py" "$OUT/cbe_full.c" "$OUT/cbe_fixed.c"

echo "==> SDCC"
cd "$OUT"
sdcc $SDCC_FLAGS -c "$POC/c/crc16.c" -o c_crc16.rel
sdcc $SDCC_FLAGS -c rs_crc16.c -o rs_crc16.rel
# SDCC has no __attribute__; rename so both Rust versions can be linked together
sdcc $SDCC_FLAGS '-D__attribute__(x)=' -Drs_crc16=cbe_crc16 -c cbe_fixed.c -o cbe_crc16.rel 2>/dev/null
sdcc $SDCC_FLAGS -c "$POC/c/main.c" -o main.rel
sdcc $SDCC_FLAGS main.rel c_crc16.rel rs_crc16.rel cbe_crc16.rel -o test.ihx

echo "==> s51"
rm -f serial.txt
# s51 does not stop on its own; the harness ends with '#' and loops
(sleep 20) | timeout 20 s51 -t 8052 -q -S out=serial.txt -g test.ihx >/dev/null 2>&1 || true
mapfile -t L < serial.txt
read -r -a R <<< "${L[0]}"
read -r -a C <<< "${L[1]}"
cyc() { echo $((16#${C[$1]}${C[$1+1]})); }
seg() { local v; v=$(awk -v s="$2" '$1=="A" && $2==s {print $4}' "$1.rel"); echo $((16#$v)); }

printf '\n%-10s %6s %6s %6s %6s %10s %10s %6s %6s\n' "" CSEG XSEG OSEG DSEG "cyc 9B" "cyc 256B" "crc9" "crc256"
row() { printf '%-10s %6d %6d %6d %6d %10d %10d %6s %6s\n' "$1" "$(seg "$2" CSEG)" "$(seg "$2" XSEG)" \
	"$(seg "$2" OSEG)" "$(seg "$2" DSEG)" "$(cyc "$3")" "$(cyc "$4")" "${R[$5]}" "${R[$6]}"; }
row "C" c_crc16 0 4 0 2
row "Rust clr" rs_crc16 2 6 1 3
row "Rust cbe" cbe_crc16 8 10 4 5
echo "(expected crc9 29b1, crc256 fe0e; cycles are 8051 machine cycles)"
