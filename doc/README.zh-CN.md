# rust-8051：让 Rust 代码跑在 8051（MCS-51）上

[English](../README.md) | 中文 | [日本語](README.ja.md)

目标：用 Rust 为 [RTLPlayground](https://github.com/logicog/RTLPlayground)（RTL8372/RTL8373 交换机里的 8051 固件）写功能模块，和现有的 C 代码链接到一起。

开坑日期：2026-09-27。**现状：第 0 阶段（概念验证）已完成**，见[第 0 阶段结果](#第-0-阶段结果)。

## 现状调研

| 路线 | 现状 | 对 RTLPlayground 的可行性 |
|---|---|---|
| LLVM 8051 后端 | LLVM 官方没有；也没找到仍在维护的第三方后端。AVR 后端从开发到合入上游用了好几年 | 从零写，工作量以年计 |
| rv51：在 8051 上模拟 RISC-V，Rust 编译成 RV32IM | 能用。模拟器用汇编写成，但要占用 8051 内部 RAM 的高 128 字节作寄存器堆 | **不可行**：RTLPlayground 的内部 RAM 已经用满，性能也会降低几十倍 |
| **Rust → C → SDCC** | `rustc_codegen_clr` 的 C 模式把 SDCC 列为"部分支持"（不支持原子操作，不支持超过 8 字节的静态量/常量）；core 库测试通过率约 95% | **最现实**，作为主路线 |
| Rust → LLVM IR → llvm-cbe → C → SDCC | llvm-cbe 是 LLVM 的 C 后端，有人在维护；前面照常用 rustc 和 LLVM 做优化，只把最后生成代码这一步交给 SDCC | 和主路线并行做概念验证 |
| Rust → C（其他编译器） | `rustc_codegen_c`（rust-lang 官方，实验性，只支持 Linux）；`mrustc`（C++ 写的另一个 Rust 编译器，输出 C，只支持较老的 Rust 版本） | 主路线走不通时再试 |

## rustc_codegen_clr 的注意事项
- 最后一次提交是 2025-10-14（`a9aa553`）。它只兼容很窄范围的 nightly，所以 `setup.sh` 会依次尝试那段时间的几个 nightly。
- 上游的测试环境是 Linux x86_64。
- C 模式用环境变量 `C_MODE=1` 开启；`ASCII_IDENTS=1` 让生成的符号名只含 ASCII 字符。
- 生成的 C 依赖 `malloc`/对齐分配（给高对齐的静态量用）和 POSIX 线程 API，在 8051 裸机上要去掉；它的 C 导出器里已经有 `#ifndef __SDCC` 分支。

## 为什么不先写 LLVM 8051 后端
好处：Rust 可以原生编译到 8051，不再有 C 方言的限制；clang、Zig 等基于 LLVM 的语言也能顺带支持；能用上 LLVM 的优化和 LTO；生态价值大。

代价：8051 寄存器极少，有多个地址空间和指针宽度，硬件栈很小，还需要代码分 bank，这些都和 LLVM 的设计假设不合。参照 AVR 后端的历史，要做到能用的质量得一到几年。

所以先用 Rust → C 做概念验证，把坑摸清楚。如果证明值得，再立项写 LLVM 后端，概念验证的经验（静态分配、内存空间、bank 调用）可以直接当作设计输入。

## 主路线的难点（Rust → C → SDCC → RTLPlayground）

1. **C 方言**：生成的 C 可能用到 128 位整数、GCC 扩展、`alignas`，或者超过 8 字节的静态初始化。这些 SDCC 都不支持，需要在后端做降级或者绕开。
2. **内存空间**：8051 内部 RAM 只有 256 字节，在 RTLPlayground 里已经满了。Rust 生成的所有变量都得放进 `__xdata`：要么用 `--model-large`，要么后端直接生成带 `__xdata` 的声明。SDCC 为复杂表达式生成的溢出临时变量也会挤占内部 RAM（在 `rtl837x_qos.c` 上已经遇到过，见 RTLPlayground issue #386）。
3. **可重入和栈**：SDCC 默认把局部变量静态分配，函数不可重入。递归、函数指针、trait 对象需要 `--stack-auto`，但内部栈只有约 150 字节，可能得用外部栈 `--xstack`。
4. **代码分 bank**：固件分成多个 48KB 的 bank，Rust 模块要整体放进某个 bank（比如 BANK3），对外接口加 `__banked`。
5. **代码体积**：泛型单态化、panic 和格式化相关的代码很占空间。需要 `panic = "abort"`，不用 `core::fmt`，开 `opt-level = "z"`。
6. **整数宽度**：`usize` 在 16 位目标上是 16 位，需要一个 16 位指针宽度的目标描述（可以参考 `msp430-none-elf` 或 `avr`）。

## 计划

### 阶段 0：概念验证——2026-10-01 完成
- [x] 装工具链：`./setup.sh`（Rust nightly、`rustc_codegen_clr`、llvm-cbe、SDCC 和 `s51`）；`./uninstall.sh` 卸载
- [x] 写一个 `#![no_std]` 的 Rust 小函数：CRC16（`poc/crc16`）
- [x] Rust → C → SDCC 编译到 mcs51，记录遇到的所有不兼容点
- [x] 在 `s51` 模拟器上跑，和手写 C 版本比较结果、代码大小和内部 RAM 占用
- [x] 用 llvm-cbe 路线做同样的对比

### 阶段 1：和 RTLPlayground 对接
- [ ] 用 Rust 重写一个小模块（候选：`rtl837x_qos.c` 里的参数解析和寄存器辅助函数，有现成的 59 项单元测试可以直接对照）
- [ ] 生成的 C 放进 BANK3，对外接口声明 `__banked`，确认内部 RAM 零增长
- [ ] 写一个 cargo 包装脚本，接进 Makefile

### 阶段 2：让它好用
- [ ] 做一个寄存器访问 crate：安全地封装 `reg_read_m` / `reg_write_m`
- [ ] 让后端识别 8051 的内存空间标注
- [ ] 评估要不要给 `rustc_codegen_clr` 提交 SDCC 相关的改进

## 使用方法

需要 Linux x86_64（在 Arch Linux 上测试过）、`rustup`、`git`、`python3`；llvm-cbe 还需要系统里装有带头文件的 LLVM。`setup.sh` 会用 brew、apt 或 pacman 安装 SDCC（需要 sudo）。

```
./setup.sh      # 装了什么都记在 .installed 里
poc/run.sh      # 编译三个版本的 CRC16，在 s51 上运行，打印下面的对比表
./uninstall.sh  # 卸载 .installed 里记录的东西，并删掉所有编译输出
```

| 路径 | 内容 |
|---|---|
| `setup.sh`、`uninstall.sh` | 安装和卸载工具链 |
| `patches/` | 对 `rustc_codegen_clr` 的本地补丁，`setup.sh` 会自动打上 |
| `poc/crc16/` | Rust 代码，用 `rustc_codegen_clr` 编译（x86_64 目标） |
| `poc/crc16-llvm/` | 同一份代码，走 llvm-cbe 路线（`msp430-none-elf`，`usize` 和指针是 16 位） |
| `poc/c/` | 手写 C 对照版本和 s51 测试程序 |
| `poc/cbe_fix.py` | 改写 llvm-cbe 的输出，绕开 SDCC 的 bug |
| `poc/sdcc-bug/repro.c` | 这个 SDCC bug 的最小复现 |

## 第 0 阶段结果

2026-10-01，Arch Linux x86_64。测试对象是 CRC-16/CCITT-FALSE（`poc/crc16/src/lib.rs`），对照组是手写 C（`poc/c/crc16.c`）。测试程序 `poc/c/main.c` 用定时器 0 数机器周期，结果从串口输出。SDCC 4.6.0，`-mmcs51 --model-large --opt-code-size`。

| 版本 | 代码（CSEG） | XDATA | 内部 RAM（OSEG） | DSEG | 周期（9 字节） | 周期（256 字节） | 结果 |
|---|---|---|---|---|---|---|---|
| 手写 C | 180 | 7 | 5 | 0 | 3368 | 95596 | 正确 |
| Rust，rustc_codegen_clr | 193（+7%） | 9 | 5 | 0 | 4752（+41%） | 132836（+39%） | 正确 |
| Rust，llvm-cbe（msp430 目标） | 435（+142%） | 46 | 6 | 0 | 6559（+95%） | 182180（+91%） | 绕开 SDCC bug 后正确 |

大小的单位是字节，周期是 8051 机器周期。`"123456789"` 的 CRC 是 0x29B1，256 字节测试数据的 CRC 是 0xFE0E。

结论：
- **主路线能跑通。** CRC 这种纯计算函数，代码只比手写 C 大 7%。慢约 40%，主要是因为生成的代码每次都重新做指针加法（`data + (uintptr_t)i`），而且 Rust 的 `while` 循环被翻译成了 goto，SDCC 优化不了。
- **目前只能把单个函数抽出来用。** 整个生成文件有 21534 行，因为 `core` 没有被裁掉，SDCC 会报 173 个错误（见下面）。阶段 1 需要让死代码消除只保留真正用到的函数，或者写一个按函数提取的工具。
- **llvm-cbe 路线的 C 短得多**（144 行，整个文件都能编译），但每个运算都变成了辅助函数调用，每个 PHI 节点都多一个临时变量，SDCC 处理得不好，代码大一倍多。把辅助函数换成宏以后，代码能降到 282 字节（试过一次，还没测周期）。
- 两条路线都用了 5～6 字节内部 RAM（OSEG，参数和局部变量的重叠区），手写 C 也一样。放进 RTLPlayground 之前，参数和局部变量都要改成 `__xdata`，这需要后端支持。

### 遇到的问题和处理方法

rustc_codegen_clr（commit a9aa553，nightly-2025-10-14）：
1. **编译 `compiler_builtins` 时崩溃**：`ERROR:calling using convention Custom is not supported!`。这个 nightly 的 `compiler_builtins` 有 `extern "custom"` 的裸函数（`__rust_probestack` 等）。本地补丁 `patches/rustc_codegen_clr-custom-abi.patch` 把它们当作 C 调用处理，`setup.sh` 会自动打上。
2. **`#[no_mangle]` 函数被删掉**：它的死代码消除只保留 `Linkage::External`，所以要导出的函数得加 `#![feature(linkage)]` 和 `#[linkage = "external"]`。
3. **`staticlib` 不会生成 C**：只有它的 linker 运行时才输出 C，所以要用 `cdylib`。C 文件在 `target/<目标>/release/deps/lib<名字>.c`。
4. **控制标识符的环境变量是 `ASCII_IDENTS=1`**，最初记成了 `ASCI_IDENT`。不设这个变量，标识符里会有 `$`，SDCC 会报 1207 个"invalid identifier"。
5. `setup.sh` 还要编译 `cilly` 包里的 `linker`，rustc 的参数里引用了它。

整个生成文件交给 SDCC 时剩下的 173 个错误（运行 `poc/run.sh` 以后执行 `sdcc -mmcs51 --model-large -c poc/out/rs_full.c` 可以复现）：
- `core` 里的 `log2f` 等浮点函数，参数个数和 SDCC 的库对不上（error 101）
- 通过函数指针调用的函数参数太多，SDCC 要求它们是 `__reentrant`（error 92）
- 不支持 `__uint128_t`、`long double`（warning 93）
- **SDCC 会截断很长的标识符**，Rust 的符号名被截断以后出现重名（error 65/91）
- `mm_malloc.h`、`alloca.h` 等头文件，以及对 `stdio`/`malloc` 的依赖
- 全部按 x86_64 处理，`usize` 是 64 位

llvm-cbe（a13fcf3，系统 LLVM 22.1，IR 来自 rustc 的 LLVM 21）：
1. SDCC 不支持 `__attribute__`，加上 `-D__attribute__(x)=` 就行。
2. **SDCC 4.6.0 的 bug**：通过通用指针的 `*(T*)(&((T*)p)[i])` 会读错字节，`((T*)p)[i]` 则没问题。最小复现在 `poc/sdcc-bug/repro.c`（大模型和小模型都会出错）。llvm-cbe 每次读内存都是这种写法，所以用 `poc/cbe_fix.py` 改写。
3. `msp430-none-elf` 目标让 `usize` 和指针都是 16 位（datalayout `p:16:16`），这是主路线目前缺的。

### 对阶段 1 的影响
- 主路线需要：16 位目标（现在是 x86_64，`usize` 是 64 位）、只输出真正用到的函数、所有变量都放进 `__xdata`。前两项可能要改 `rustc_codegen_clr` 的 C 导出器。
- llvm-cbe 路线已经有 16 位目标，输出也短，缺的是性能。可以在 `cbe_fix.py` 里把辅助函数换成宏，并合并 PHI 临时变量。值得和主路线并排继续比较。

## 参考
- rustc_codegen_clr: https://github.com/FractalFir/rustc_codegen_clr
- rustc_codegen_c: https://github.com/rust-lang/rustc_codegen_c
- mrustc: https://github.com/thepowersgang/mrustc
- llvm-cbe: https://github.com/JuliaHubOSS/llvm-cbe
- rv51: https://github.com/cyrozap/rv51
- i8051，用 Rust 写的 8051 模拟器，可以用来做测试: https://github.com/mmastrac/i8051
- Embedonomicon 里关于编译器支持的说明: https://docs.rust-embedded.org/embedonomicon/compiler-support.html

## 许可证

可以任选 [Apache License, Version 2.0](../LICENSE-APACHE) 或 [MIT license](../LICENSE-MIT)。
