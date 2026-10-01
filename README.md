# rust-8051: Rust on the 8051 (MCS-51)

Goal: write feature modules for [RTLPlayground](https://github.com/logicog/RTLPlayground), the 8051 firmware of
RTL8372/RTL8373 switches, in Rust and link them with the existing C code.

Started 2026-09-27. **Status: phase 0 (proof of concept) done**, see [Phase 0 results](#phase-0-results).

## Survey

| Route | State | Fit for RTLPlayground |
|---|---|---|
| LLVM 8051 backend | Not in upstream LLVM; no maintained third-party backend found. The AVR backend took years to get upstream | Written from scratch, years of work |
| rv51: RISC-V emulated on the 8051, Rust compiled to RV32IM | Works. The emulator is written in assembly but uses the upper 128 bytes of internal RAM as its register file | **Not feasible**: RTLPlayground's internal RAM is full, and it is tens of times slower |
| **Rust → C → SDCC** | `rustc_codegen_clr`'s C mode lists SDCC as partially supported (no atomics, no statics/constants over 8 bytes); about 95% of the core tests pass | **Most realistic**, the main route |
| Rust → LLVM IR → llvm-cbe → C → SDCC | llvm-cbe is a maintained C backend for LLVM; rustc and LLVM optimize as usual and only code generation goes through SDCC | Tried in parallel with the main route |
| Rust → C, other compilers | `rustc_codegen_c` (rust-lang, experimental, Linux only); `mrustc` (alternative Rust compiler in C++, emits C, older Rust only) | Fallback if the main route fails |

## Notes on rustc_codegen_clr
- Last commit 2025-10-14 (`a9aa553`). It builds only with a narrow range of nightlies, so `setup.sh` tries several from that time.
- Tested by upstream on Linux x86_64.
- C mode is enabled with `C_MODE=1`; `ASCII_IDENTS=1` makes the generated identifiers ASCII only.
- The generated C depends on `malloc`/aligned allocation (for highly aligned statics) and POSIX threads, which must go
  on a bare 8051; its C exporter already has `#ifndef __SDCC` branches.

## Why not an LLVM 8051 backend first
Benefits: native Rust on the 8051 without the limits of a C dialect; clang, Zig and other LLVM languages for free;
LLVM's optimizations and LTO; large ecosystem value.

Cost: very few registers, several address spaces and pointer widths, a tiny hardware stack and banked code all clash
with LLVM's assumptions. Judging by the AVR backend, reaching usable quality takes one to several years.

So the Rust → C route comes first to map out the problems. If it proves worthwhile, an LLVM backend can follow, and
the experience (static allocation, memory spaces, banked calls) becomes its design input.

## Challenges of the main route (Rust → C → SDCC → RTLPlayground)

1. **C dialect**: the generated C may use 128-bit integers, GCC extensions, `alignas` or static initializers over
   8 bytes. SDCC supports none of these; the backend has to lower or avoid them.
2. **Memory spaces**: the 8051 has 256 bytes of internal RAM, and RTLPlayground has used it all. Everything Rust
   generates must live in `__xdata`, either via `--model-large` or with `__xdata` emitted by the backend. Spill
   temporaries that SDCC creates for complex expressions also take internal RAM (seen in `rtl837x_qos.c`, see
   RTLPlayground issue #386).
3. **Reentrancy and stack**: SDCC allocates locals statically, so functions are not reentrant. Recursion, function
   pointers and trait objects need `--stack-auto`, but the internal stack is only about 150 bytes, so the external
   stack (`--xstack`) may be needed.
4. **Code banks**: the firmware is split into 48 KB banks. A Rust module must go into one bank as a whole (e.g. BANK3)
   with `__banked` entry points.
5. **Code size**: monomorphization, panics and formatting are expensive. Use `panic = "abort"`, avoid `core::fmt`,
   use `opt-level = "z"`.
6. **Integer width**: `usize` is 16 bits on a 16-bit target, so a target description with 16-bit pointers is needed
   (see `msp430-none-elf` or `avr`).

## Plan

### Phase 0: proof of concept — done 2026-10-01
- [x] Toolchain: `./setup.sh` (Rust nightly, `rustc_codegen_clr`, llvm-cbe, SDCC and `s51`); `./uninstall.sh` removes it
- [x] A small `#![no_std]` Rust function: CRC16 (`poc/crc16`)
- [x] Rust → C → SDCC for mcs51, recording every incompatibility
- [x] Run on the `s51` simulator and compare result, code size and internal RAM with hand-written C
- [x] The same comparison through llvm-cbe

### Phase 1: integrate with RTLPlayground
- [ ] Rewrite a small module in Rust (candidate: the argument parsing and register helpers of `rtl837x_qos.c`, which
      come with 59 unit tests to compare against)
- [ ] Put the generated C into BANK3 with `__banked` entry points, with zero growth of internal RAM
- [ ] A cargo wrapper script, hooked into the Makefile

### Phase 2: make it pleasant
- [ ] A register access crate that wraps `reg_read_m` / `reg_write_m` safely
- [ ] Teach the backend 8051 memory space annotations
- [ ] Consider upstreaming SDCC improvements to `rustc_codegen_clr`

## Usage

Linux x86_64 (tested on Arch Linux). Needs `rustup`, `git`, `python3` and, for llvm-cbe, the system LLVM with
headers; `setup.sh` installs SDCC with brew, apt or pacman (sudo).

```
./setup.sh      # records everything it installs in .installed
poc/run.sh      # builds the three CRC16 versions, runs them in s51 and prints the table below
./uninstall.sh  # removes what .installed lists and all build outputs
```

| Path | Content |
|---|---|
| `setup.sh`, `uninstall.sh` | Install and remove the toolchain |
| `patches/` | Local patches to `rustc_codegen_clr`, applied by `setup.sh` |
| `poc/crc16/` | The Rust code, built with `rustc_codegen_clr` (x86_64 target) |
| `poc/crc16-llvm/` | The same code for the llvm-cbe route (`msp430-none-elf`, 16-bit `usize` and pointers) |
| `poc/c/` | Hand-written C reference and the s51 test harness |
| `poc/cbe_fix.py` | Rewrites llvm-cbe output around an SDCC bug |
| `poc/sdcc-bug/repro.c` | Minimal reproducer of that SDCC bug |

## Phase 0 results

2026-10-01, Arch Linux x86_64. The function is CRC-16/CCITT-FALSE (`poc/crc16/src/lib.rs`), compared with
hand-written C (`poc/c/crc16.c`). The harness `poc/c/main.c` counts machine cycles with timer 0 and prints over the
serial port. SDCC 4.6.0, `-mmcs51 --model-large --opt-code-size`.

| Version | Code (CSEG) | XDATA | Internal RAM (OSEG) | DSEG | Cycles, 9 bytes | Cycles, 256 bytes | Result |
|---|---|---|---|---|---|---|---|
| Hand-written C | 180 | 7 | 5 | 0 | 3368 | 95596 | correct |
| Rust, rustc_codegen_clr | 193 (+7%) | 9 | 5 | 0 | 4752 (+41%) | 132836 (+39%) | correct |
| Rust, llvm-cbe (msp430 target) | 435 (+142%) | 46 | 6 | 0 | 6559 (+95%) | 182180 (+91%) | correct with the SDCC workaround |

Sizes in bytes, cycles are 8051 machine cycles. The CRC of `"123456789"` is 0x29B1, of the 256-byte test data 0xFE0E.

Conclusions:
- **The main route works.** For a pure computation like CRC the code is only 7% larger than hand-written C. It is
  about 40% slower, mostly because the generated code redoes the pointer addition (`data + (uintptr_t)i`) every time
  and turns Rust's `while` loops into gotos that SDCC cannot optimize.
- **Only single functions can be used so far.** The whole generated file has 21534 lines because `core` is not
  trimmed, and SDCC reports 173 errors on it (see below). Phase 1 needs dead code elimination that keeps only what is
  used, or a tool that extracts functions.
- **The llvm-cbe C is much shorter** (144 lines, the whole file compiles), but every operation becomes a helper call
  and every PHI node an extra temporary, which SDCC handles poorly: more than twice the code. With the helpers turned
  into macros the code drops to 282 bytes (tried once, cycles not measured yet).
- Both routes use 5–6 bytes of internal RAM (OSEG, the overlay for parameters and locals), as does the hand-written
  C. For RTLPlayground, parameters and locals must move to `__xdata`, which needs backend support.

### Problems found and how they were handled

rustc_codegen_clr (commit a9aa553, nightly-2025-10-14):
1. **Crash while compiling `compiler_builtins`**: `ERROR:calling using convention Custom is not supported!`. This
   nightly's `compiler_builtins` has naked `extern "custom"` functions (`__rust_probestack` and others). The local
   patch `patches/rustc_codegen_clr-custom-abi.patch` treats them like C calls; `setup.sh` applies it.
2. **`#[no_mangle]` functions are removed**: only `Linkage::External` survives its dead code elimination, so exported
   functions need `#![feature(linkage)]` and `#[linkage = "external"]`.
3. **A `staticlib` produces no C**: C is only written when its linker runs, so use `cdylib`. The file lands in
   `target/<target>/release/deps/lib<name>.c`.
4. **The identifier option is `ASCII_IDENTS=1`**, not `ASCI_IDENT` as first noted. Without it identifiers contain `$`
   and SDCC reports 1207 "invalid identifier" errors.
5. `setup.sh` must also build the `linker` binary from the `cilly` crate, which the rustc flags point at.

The 173 errors left when SDCC compiles the whole generated file
(`sdcc -mmcs51 --model-large -c poc/out/rs_full.c` after `poc/run.sh`):
- Float functions such as `log2f` from `core` disagree with SDCC's library on the parameter count (error 101)
- Functions called through pointers take too many parameters; SDCC wants them `__reentrant` (error 92)
- No `__uint128_t` or `long double` (warning 93)
- **SDCC truncates long identifiers**, and truncated Rust symbol names collide (errors 65/91)
- Headers such as `mm_malloc.h` and `alloca.h`, and dependencies on `stdio`/`malloc`
- Everything is sized for x86_64; `usize` is 64 bits

llvm-cbe (a13fcf3, system LLVM 22.1, IR from rustc's LLVM 21):
1. SDCC has no `__attribute__`; `-D__attribute__(x)=` is enough.
2. **SDCC 4.6.0 bug**: `*(T*)(&((T*)p)[i])` through a generic pointer reads the wrong byte, while `((T*)p)[i]` is
   correct. Minimal reproducer in `poc/sdcc-bug/repro.c` (fails with both the large and the small model). llvm-cbe
   emits exactly this form for every load, so `poc/cbe_fix.py` rewrites it.
3. The `msp430-none-elf` target gives 16-bit `usize` and pointers (datalayout `p:16:16`), which the main route lacks.

### What this means for phase 1
- The main route needs a 16-bit target (now x86_64 with a 64-bit `usize`), output limited to the functions actually
  used, and all variables in `__xdata`. The first two probably mean changes to `rustc_codegen_clr`'s C exporter.
- The llvm-cbe route already has a 16-bit target and short output; it lacks performance. `cbe_fix.py` could turn the
  helpers into macros and merge PHI temporaries. Worth keeping side by side with the main route.

## References
- rustc_codegen_clr: https://github.com/FractalFir/rustc_codegen_clr
- rustc_codegen_c: https://github.com/rust-lang/rustc_codegen_c
- mrustc: https://github.com/thepowersgang/mrustc
- llvm-cbe: https://github.com/JuliaHubOSS/llvm-cbe
- rv51: https://github.com/cyrozap/rv51
- i8051, an 8051 emulator in Rust, usable for tests: https://github.com/mmastrac/i8051
- Embedonomicon on compiler support: https://docs.rust-embedded.org/embedonomicon/compiler-support.html
