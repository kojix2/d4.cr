# 約1 GBの D4 による Crystal / Rust 比較

2026-10-09。Crystal 1.21.1 `--release`、Rust d4binding / d4tools 0.3.11、Linux x86-64。Rust C API で生成した同じファイルを各実装で読み取った。一次データは 2,863,267,840 塩基、1,073,728,008 バイト（ほぼ 1 GiB）。二次データは 100,000,000 塩基、1,000,009,864 バイト（約 1 GB）。索引なし、CLI は `-t 1 --no-index`。

## 連続走査と総和

| データ | 実装・経路 | 時間中央値 | 最大 RSS 中央値 | 総和 |
|---|---|---:|---:|---:|
| 一次データ 約1 GiB | Crystal `scan_values` | **7.58 秒** | **2.8 MiB** | 10,021,437,440 |
| 同じファイル | Rust C API `d4_file_read_values` | 18.06 秒 | 1,026 MiB | 同上 |
| 同じファイル | Rust CLI `stat -s sum` | **6.26 秒** | 1,029 MiB | 同上 |
| 二次データ 約1 GB | Crystal `scan_values` | 1.35 秒 | 6.8 MiB | 150,000,000 |
| 同じファイル | Rust C API `d4_file_read_values` | 1.01 秒 | 956 MiB | 同上 |
| 同じファイル | Rust CLI `stat -s sum` | **0.68 秒** | 959 MiB | 同上 |

4 回ずつ独立した子プロセスで測定し、最初を除く 3 回の中央値を示した。65,536 個の `Int32` バッファを使う Crystal と Rust C API は値をすべてアプリケーションに渡して加算した。Rust CLI は内部の集計経路であり、同じ処理を行う API の速度ではない。ローカルのページキャッシュが温まった条件である。Crystal の累積 GC 割り当ては一次データ約 340 KiB、二次データ約 4.53 MiBだった。

一次データでは Crystal は Rust C API より約 2.4 倍速く、Rust CLI より約 1.2 倍遅い。二次データでは Crystal は Rust C API より約 1.3 倍、Rust CLI より約 2.0 倍遅い。この2種類だけでも性能の順位は変わる。

## 書き込み（各1回）

| 出力 | Crystal | Rust C API | Crystal / Rust 時間比 | Crystal 最大 RSS | Rust 最大 RSS |
|---|---:|---:|---:|---:|---:|
| 一次データ 約1 GiB | 261.94 秒 | 28.91 秒 | 9.1 倍 | 3.4 MiB | 1,026 MiB |
| 二次データ 約1 GB | 13.62 秒 | 1.87 秒 | 7.3 倍 | 3.4 MiB | 4.3 MiB |

値の生成、65,536 値ずつの公開 API 書き込み、完成処理を含む。時間のかかる一次データ書き込みは各実装1回のみなので、走査の中央値ほど安定した推定ではない。Crystal 出力のサイズは一次 1,073,727,512 バイト、二次 1,000,246,232 バイト。両方を Rust CLI で読み、総和が一致した。

## RSS の意味

一次データ走査中に `/proc/<pid>/smaps_rollup` を 0.25 秒間隔で別途観察した。これは上の時間計測とは別の代表実行である。

| 実装 | 観測最大 RSS | ファイル由来 PSS の最大 | 匿名メモリ PSS の最大 |
|---|---:|---:|---:|
| Crystal | 約 3.0 MiB | 約 1.0 MiB | 約 1.4 MiB |
| Rust C API | 約 1,023 MiB | 約 1,022 MiB | 約 0.61 MiB |
| Rust CLI | 約 1,028 MiB | 約 1,026 MiB | 約 0.88 MiB |

**Rust の約1 GiBの RSS は主にファイルマッピングであり、1 GiB のヒープ確保を示さない。** ファイルページは OS のキャッシュと関連し、メモリ圧迫時に回収できる。したがって、この条件で Crystal の RSS が小さいことを「Rust よりヒープ効率が高い」と言い換えるのは不正確である。他方、プロセスの RSS 上限を監視する環境ではこの差は実際に見える。

この結果は温まったローカルファイルと合成値の2条件だけである。キャッシュに収まらない 10 GB 級ファイル、圧縮、索引付きランダム参照、複数並列読者、実際の WGS 深度分布の速度・メモリを代表しない。入力が何を「10 GB 消費」するかは、RSS、匿名メモリ、ファイルマッピング、ページキャッシュを分けて再計測する必要がある。

再現コードは `bench/compare.cr`、`bench/compare.c`、`bench/measure.c`、`bench/run_1g_comparison.py`。全4回の計測値は別添 JSON 3 件、PSS の観察値は `d4-1g-memory-breakdown-20261009.json` に保存した。1 GB の入力ファイル自体は同梱しない。

`compare.c` を `d4binding` にリンクした実行ファイルを `/tmp/d4-rust-compare` とした場合の入力生成例:

```sh
/tmp/d4-rust-compare generate /tmp/d4-primary-1g.d4 2863267840 primary
/tmp/d4-rust-compare generate /tmp/d4-secondary-1g.d4 100000000 alternate
python3 bench/run_1g_comparison.py --program all
```

比較用バイナリや出力先はスクリプトの `D4_*` 環境変数で指定できる。
