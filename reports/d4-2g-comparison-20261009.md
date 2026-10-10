# 約2 GBの D4 による Crystal / Rust 比較

2026-10-09。Crystal 1.21.1 `--release`、Rust d4binding / d4tools 0.3.11、Linux x86-64、利用可能メモリ約9.7 GiB。Rust C API が生成した**同じファイル**を各実装で読み、総和を照合した。一次データは 2,863,267,840 塩基の染色体2本、2,147,453,960 バイト（ほぼ2 GiB）。二次データは2億塩基の染色体1本、2,000,017,496 バイト（約2 GB）。索引なし、CLI は1スレッド。

## 読み取り

| データ | Crystal の走査 | Rust C API の走査 | Rust CLI の総和 | Crystal 最大 RSS | Rust C API 最大 RSS |
|---|---:|---:|---:|---:|---:|
| 一次データ 約2 GiB | **17.60 秒** | 37.31 秒 | **12.51 秒** | **2.8 MiB** | 約2,050 MiB |
| 二次データ 約2 GB | 2.67 秒 | **2.17 秒** | **1.49 秒** | **6.8 MiB** | 約1,910 MiB |

65,536 個の `Int32` を再利用して全値を読み、Crystal と Rust C API は加算した。CLI `stat -s sum --no-index -t 1` は内部集計経路であり、各値を公開 API から取り出す処理とは異なる。別プロセスで4回ずつ計測し、最初を除く3回の中央値。一次データの総和は両染色体あわせて **20,042,874,880**、二次データは **300,000,000** で全経路が一致した。

Crystal の累積 GC 割り当ては一次データ約367 KiB、二次データ約4.55 MB。二次データの Crystal 走査は4回で **6.04、3.59、2.67、2.59秒** とばらついた。最初の1回を除いてもキャッシュ等の条件が完全に安定したとは言えない。

## 書き込み（各1回）

| 出力 | Crystal | Rust C API | 時間比 Crystal / Rust | Crystal 最大 RSS | Rust 最大 RSS |
|---|---:|---:|---:|---:|---:|
| 一次データ 約2 GiB | 631.43 秒 | 43.57 秒 | **14.5倍** | 3.4 MiB | 約2,050 MiB |
| 二次データ 約2 GB | 37.43 秒 | 4.45 秒 | **8.4倍** | 3.6 MiB | 4.2 MiB |

値の生成、公開 API への65,536値単位の入力、完成時のファイル処理を含む。一次データの Crystal 出力は 2,147,452,968 バイト、二次データは 2,000,490,392 バイト。Rust CLI は Crystal 出力について、一次の各染色体が **10,021,437,440**、二次が **300,000,000** と確認した。一次書き込みは約10.5分を要し、**各実装1回だけ**の測定である。1 GBでの約9.1倍との差が拡大した理由を、この2点だけからアルゴリズムの非線形性と断定できない。ディスク書き込み、キャッシュ、CPUの変動も含まれる。

## RSS とファイルマッピング

一次データ走査中の `/proc/<pid>/smaps_rollup` を、時間測定とは別の代表実行で0.25秒間隔に観察した。

| 実装 | 観測最大 RSS | ファイル由来 PSS の最大 | 匿名メモリ PSS の最大 |
|---|---:|---:|---:|
| Crystal | 3.0 MiB | 1.0 MiB | 1.4 MiB |
| Rust C API | 約2,044 MiB | 約2,043 MiB | 0.61 MiB |
| Rust CLI | 約2,025 MiB | 約2,023 MiB | 1.07 MiB |

Rust の大きい RSS のほぼ全ては**ファイル由来のマッピング**で、ヒープを2 GiB確保したという意味ではない。ファイルページは匿名メモリと比べて OS が回収しやすい。一方、RSS 監視やプロセスの実効メモリ上限では差が見える。PSS の各列の最大値は必ずしも同時刻ではない。

## 1 GBとの比較と限界

一次データの Crystal 走査は1 GBの7.58秒から2 GBの17.60秒、Rust C API は18.06秒から37.31秒、Rust CLI は6.26秒から12.51秒。二次データの Crystal 走査は1.35秒から2.67秒、Rust C API は1.01秒から2.17秒、Rust CLI は0.68秒から1.49秒。合成値でのローカル連続走査はおおむねファイル量に応じて増えたが、一次データの Crystal には約2.3倍の増加が見えた。キャッシュに収まらない 10 GB、実際の WGS 値分布、圧縮や多数のランダムアクセスにそのまま外挿しない。

再現コードは `bench/compare.cr`、`bench/compare.c`、`bench/measure.c`、`bench/run_1g_comparison.py --scale 2`。入力生成は次の通り（実行ファイルは各自の環境で d4binding にリンクして用意する）。

```sh
/tmp/d4-rust-compare-dual generate-dual /tmp/d4-primary-2g.d4 2863267840
/tmp/d4-rust-compare-dual generate /tmp/d4-secondary-2g.d4 200000000 alternate
D4_CRYSTAL_COMPARE_BIN=/tmp/d4-crystal-compare-dual D4_RUST_COMPARE_BIN=/tmp/d4-rust-compare-dual python3 bench/run_1g_comparison.py --scale 2
```

4回分の時間・RSS・CPU時間は別添の Crystal / Rust C API / Rust CLI の JSON、ファイル・匿名メモリの内訳は `d4-2g-memory-breakdown-20261009.json` に保存した。約2 GBの入力ファイル自体は同梱しない。
