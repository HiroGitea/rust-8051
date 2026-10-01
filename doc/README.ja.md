# rust-8051：Rust を 8051（MCS-51）で動かす

[English](../README.md) | [中文](README.zh-CN.md) | 日本語

目的：[RTLPlayground](https://github.com/logicog/RTLPlayground)（RTL8372/RTL8373 スイッチの 8051 ファームウェア）の機能モジュールを Rust で書き、既存の C コードとリンクすること。

開始：2026-09-27。**現状：フェーズ 0（概念実証）完了**。[フェーズ 0 の結果](#フェーズ-0-の結果)を参照。

## 調査

| ルート | 現状 | RTLPlayground での実現性 |
|---|---|---|
| LLVM の 8051 バックエンド | LLVM 本家にはなく、保守されているサードパーティ製も見つからない。AVR バックエンドは本家に入るまで何年もかかった | ゼロから書くことになり、年単位の作業 |
| rv51：8051 上で RISC-V をエミュレートし、Rust を RV32IM にコンパイル | 動く。エミュレータはアセンブリで書かれているが、内部 RAM の上位 128 バイトをレジスタファイルに使う | **不可**：RTLPlayground の内部 RAM は使い切っており、速度も数十分の一になる |
| **Rust → C → SDCC** | `rustc_codegen_clr` の C モードは SDCC を「一部対応」としている（アトミック操作なし、8 バイトを超える static/定数なし）。core のテストは約 95% が通る | **最も現実的**。メインルート |
| Rust → LLVM IR → llvm-cbe → C → SDCC | llvm-cbe は保守されている LLVM の C バックエンド。最適化は通常どおり rustc と LLVM が行い、コード生成だけ SDCC に任せる | メインルートと並行して検証 |
| Rust → C（他のコンパイラ） | `rustc_codegen_c`（rust-lang 公式、実験的、Linux のみ）、`mrustc`（C++ 製の別の Rust コンパイラで C を出力、古い Rust のみ） | メインルートが駄目な場合の予備 |

## rustc_codegen_clr の注意点
- 最終コミットは 2025-10-14（`a9aa553`）。ビルドできる nightly の範囲が狭いため、`setup.sh` はその時期の nightly を順に試す。
- 上流のテスト環境は Linux x86_64。
- C モードは `C_MODE=1` で有効になる。`ASCII_IDENTS=1` で生成される識別子が ASCII のみになる。
- 生成される C は `malloc`/アラインされた確保（アラインメントの大きい static 用）と POSIX スレッドに依存しており、ベアメタルの 8051 では取り除く必要がある。C エクスポータにはすでに `#ifndef __SDCC` の分岐がある。

## なぜ先に LLVM の 8051 バックエンドを書かないのか
利点：C 方言の制約なしに Rust をネイティブに 8051 へコンパイルできる。clang や Zig など LLVM ベースの言語も使えるようになる。LLVM の最適化と LTO が使える。エコシステムへの価値が大きい。

コスト：レジスタが非常に少ない、アドレス空間とポインタ幅が複数ある、ハードウェアスタックが小さい、コードのバンク切り替えが要る。どれも LLVM の前提と合わない。AVR バックエンドの経緯からすると、実用的な品質までに 1 年から数年かかる。

そこで、まず Rust → C で問題点を洗い出す。価値があると分かれば LLVM バックエンドに取り組み、概念実証で得た知見（静的割り当て、メモリ空間、バンク呼び出し）をそのまま設計に活かす。

## メインルートの課題（Rust → C → SDCC → RTLPlayground）

1. **C 方言**：生成される C は 128 ビット整数、GCC 拡張、`alignas`、8 バイトを超える static 初期化子を使うことがある。SDCC はどれにも対応しておらず、バックエンドで変換するか避ける必要がある。
2. **メモリ空間**：8051 の内部 RAM は 256 バイトしかなく、RTLPlayground では使い切っている。Rust が生成する変数はすべて `__xdata` に置く必要がある（`--model-large` を使うか、バックエンドが `__xdata` 付きで宣言を出す）。複雑な式に対して SDCC が作る退避用の一時変数も内部 RAM を使う（`rtl837x_qos.c` で実際に起きた。RTLPlayground issue #386 参照）。
3. **再入可能性とスタック**：SDCC はローカル変数を静的に割り当てるので、関数は再入可能ではない。再帰、関数ポインタ、トレイトオブジェクトには `--stack-auto` が必要だが、内部スタックは約 150 バイトしかないため、外部スタック（`--xstack`）が必要になるかもしれない。
4. **コードバンク**：ファームウェアは 48KB のバンクに分かれている。Rust のモジュールは一つのバンク（例えば BANK3）にまとめて置き、外部向けの関数には `__banked` を付ける。
5. **コードサイズ**：単相化、panic、フォーマット関連のコードは大きい。`panic = "abort"` にし、`core::fmt` を使わず、`opt-level = "z"` にする。
6. **整数幅**：16 ビットのターゲットでは `usize` は 16 ビットなので、16 ビットポインタのターゲット定義が必要（`msp430-none-elf` や `avr` が参考になる）。

## 計画

### フェーズ 0：概念実証 —— 2026-10-01 完了
- [x] ツールチェーン：`./setup.sh`（Rust nightly、`rustc_codegen_clr`、llvm-cbe、SDCC、`s51`）。`./uninstall.sh` で削除
- [x] 小さな `#![no_std]` の Rust 関数：CRC16（`poc/crc16`）
- [x] Rust → C → SDCC で mcs51 向けにコンパイルし、非互換点をすべて記録
- [x] `s51` シミュレータで実行し、手書きの C と結果、コードサイズ、内部 RAM を比較
- [x] llvm-cbe ルートでも同じ比較

### フェーズ 1：RTLPlayground への組み込み
- [ ] 小さなモジュールを Rust で書き直す（候補：`rtl837x_qos.c` の引数解析とレジスタ補助関数。比較に使える 59 項目の単体テストがある）
- [ ] 生成した C を BANK3 に置き、外部向け関数に `__banked` を付け、内部 RAM が増えないことを確認
- [ ] cargo のラッパースクリプトを作り、Makefile に組み込む

### フェーズ 2：使いやすくする
- [ ] `reg_read_m` / `reg_write_m` を安全に包むレジスタアクセス用 crate
- [ ] バックエンドに 8051 のメモリ空間指定を理解させる
- [ ] SDCC 関連の改善を `rustc_codegen_clr` 本家に提出するか検討

## 使い方

Linux x86_64（Arch Linux で確認）、`rustup`、`git`、`python3` が必要。llvm-cbe にはヘッダ付きのシステム LLVM も必要。`setup.sh` は brew、apt、pacman のいずれかで SDCC をインストールする（sudo が必要）。

```
./setup.sh      # インストールしたものは .installed に記録される
poc/run.sh      # 3 種類の CRC16 をビルドして s51 で実行し、下の比較表を表示する
./uninstall.sh  # .installed に記録されたものとビルド出力をすべて削除する
```

| パス | 内容 |
|---|---|
| `setup.sh`、`uninstall.sh` | ツールチェーンのインストールと削除 |
| `patches/` | `rustc_codegen_clr` へのローカルパッチ。`setup.sh` が自動で当てる |
| `poc/crc16/` | Rust のコード。`rustc_codegen_clr` でビルド（x86_64 ターゲット） |
| `poc/crc16-llvm/` | 同じコードを llvm-cbe ルートでビルド（`msp430-none-elf`、`usize` とポインタは 16 ビット） |
| `poc/c/` | 手書き C の比較用実装と s51 用テストプログラム |
| `poc/cbe_fix.py` | SDCC のバグを避けるため llvm-cbe の出力を書き換える |
| `poc/sdcc-bug/repro.c` | その SDCC バグの最小再現 |

## フェーズ 0 の結果

2026-10-01、Arch Linux x86_64。対象は CRC-16/CCITT-FALSE（`poc/crc16/src/lib.rs`）、比較対象は手書きの C（`poc/c/crc16.c`）。テストプログラム `poc/c/main.c` はタイマー 0 でマシンサイクルを数え、結果をシリアルポートに出力する。SDCC 4.6.0、`-mmcs51 --model-large --opt-code-size`。

| 版 | コード（CSEG） | XDATA | 内部 RAM（OSEG） | DSEG | サイクル（9 バイト） | サイクル（256 バイト） | 結果 |
|---|---|---|---|---|---|---|---|
| 手書き C | 180 | 7 | 5 | 0 | 3368 | 95596 | 正しい |
| Rust、rustc_codegen_clr | 193（+7%） | 9 | 5 | 0 | 4752（+41%） | 132836（+39%） | 正しい |
| Rust、llvm-cbe（msp430 ターゲット） | 435（+142%） | 46 | 6 | 0 | 6559（+95%） | 182180（+91%） | SDCC バグ回避後に正しい |

サイズの単位はバイト、サイクルは 8051 のマシンサイクル。`"123456789"` の CRC は 0x29B1、256 バイトのテストデータの CRC は 0xFE0E。

結論：
- **メインルートは動く。** CRC のような純粋な計算なら、コードは手書き C より 7% 大きいだけ。約 40% 遅いのは、生成コードが毎回ポインタ加算（`data + (uintptr_t)i`）をやり直すことと、Rust の `while` ループが goto に変換されて SDCC が最適化できないことが主な原因。
- **今のところ関数単位でしか使えない。** `core` が削られないため生成ファイル全体は 21534 行あり、SDCC は 173 個のエラーを出す（下記）。フェーズ 1 では、実際に使う関数だけを残すデッドコード除去か、関数を抜き出すツールが必要。
- **llvm-cbe の C はずっと短い**（144 行、ファイル全体がコンパイルできる）。ただし演算ごとに補助関数呼び出しになり、PHI ノードごとに一時変数が増え、SDCC はこれをうまく扱えないため、コードは 2 倍以上になる。補助関数をマクロに置き換えると 282 バイトまで減る（一度試しただけで、サイクルは未計測）。
- どちらのルートも内部 RAM を 5～6 バイト使う（OSEG、引数とローカル変数のオーバーレイ領域）。手書き C も同じ。RTLPlayground に入れるには引数とローカル変数を `__xdata` に移す必要があり、バックエンドの対応が要る。

### 見つかった問題と対処

rustc_codegen_clr（commit a9aa553、nightly-2025-10-14）：
1. **`compiler_builtins` のコンパイル中にクラッシュ**：`ERROR:calling using convention Custom is not supported!`。この nightly の `compiler_builtins` には `extern "custom"` の naked 関数（`__rust_probestack` など）がある。ローカルパッチ `patches/rustc_codegen_clr-custom-abi.patch` でこれを C の呼び出しとして扱う。`setup.sh` が自動で当てる。
2. **`#[no_mangle]` の関数が消される**：デッドコード除去で残るのは `Linkage::External` だけなので、エクスポートする関数には `#![feature(linkage)]` と `#[linkage = "external"]` が必要。
3. **`staticlib` では C が出力されない**：C はリンカが動くときにだけ書き出されるので、`cdylib` を使う。ファイルは `target/<ターゲット>/release/deps/lib<名前>.c` に出る。
4. **識別子のオプションは `ASCII_IDENTS=1`**（最初は誤って `ASCI_IDENT` と記録していた）。これがないと識別子に `$` が入り、SDCC が「invalid identifier」を 1207 個出す。
5. `setup.sh` は `cilly` crate の `linker` もビルドする必要がある。rustc のフラグがこれを指している。

生成ファイル全体を SDCC でコンパイルしたときに残る 173 個のエラー（`poc/run.sh` の後に `sdcc -mmcs51 --model-large -c poc/out/rs_full.c` で再現）：
- `core` の `log2f` などの浮動小数点関数が、SDCC のライブラリと引数の数で食い違う（error 101）
- 関数ポインタ経由で呼ばれる関数の引数が多すぎ、SDCC は `__reentrant` を要求する（error 92）
- `__uint128_t` と `long double` がない（warning 93）
- **SDCC は長い識別子を切り詰める**ため、切り詰められた Rust のシンボル名が衝突する（error 65/91）
- `mm_malloc.h`、`alloca.h` などのヘッダと、`stdio`/`malloc` への依存
- すべて x86_64 前提で、`usize` は 64 ビット

llvm-cbe（a13fcf3、システムの LLVM 22.1、IR は rustc の LLVM 21 から）：
1. SDCC には `__attribute__` がない。`-D__attribute__(x)=` で足りる。
2. **SDCC 4.6.0 のバグ**：汎用ポインタ経由の `*(T*)(&((T*)p)[i])` は間違ったバイトを読む。`((T*)p)[i]` なら正しい。最小再現は `poc/sdcc-bug/repro.c`（ラージモデルでもスモールモデルでも失敗する）。llvm-cbe はすべてのロードをこの形で出力するので、`poc/cbe_fix.py` で書き換える。
3. `msp430-none-elf` ターゲットでは `usize` とポインタが 16 ビットになる（datalayout `p:16:16`）。これはメインルートに今欠けている点。

### フェーズ 1 への影響
- メインルートに必要なもの：16 ビットのターゲット（今は x86_64 で `usize` が 64 ビット）、実際に使う関数だけの出力、すべての変数を `__xdata` に置くこと。最初の二つはおそらく `rustc_codegen_clr` の C エクスポータの変更が要る。
- llvm-cbe ルートは 16 ビットのターゲットと短い出力をすでに持っており、足りないのは性能。`cbe_fix.py` で補助関数をマクロにし、PHI の一時変数をまとめられる。メインルートと並べて比較を続ける価値がある。

## 参考
- rustc_codegen_clr: https://github.com/FractalFir/rustc_codegen_clr
- rustc_codegen_c: https://github.com/rust-lang/rustc_codegen_c
- mrustc: https://github.com/thepowersgang/mrustc
- llvm-cbe: https://github.com/JuliaHubOSS/llvm-cbe
- rv51: https://github.com/cyrozap/rv51
- i8051（Rust 製の 8051 エミュレータ、テストに使える）: https://github.com/mmastrac/i8051
- Embedonomicon のコンパイラ対応の説明: https://docs.rust-embedded.org/embedonomicon/compiler-support.html

## ライセンス

[Apache License, Version 2.0](../LICENSE-APACHE) または [MIT license](../LICENSE-MIT) のいずれかを選んで利用できます。
