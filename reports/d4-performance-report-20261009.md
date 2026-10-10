# d4.cr と Rust d4-format の性能・メモリ比較

> この文書は最適化前の記録です。後続の実装と同一条件での再計測は `d4-optimization-report-20261009.md` を参照してください。特に索引相互運用の問題は後続の実装で修正されています。

2026-10-09。Crystal 1.21.1、Rust d4tools 0.3.11 / d4binding 0.3.11（Bioconda 配布バイナリ）、Linux x86-64 / AMD EPYC 9V74、利用可能メモリ約 9.7 GiB。Crystal は `--release`、C の測定器は `gcc -O3`。データは Rust D4 C API で生成し、両実装で同じ値と総和を照合した。索引なし、原則単一スレッド。

## 測り方

- 同一 D4 ファイルを別々のプロセスで読み、最初の 1 回を除いた 3 回の中央値。ファイルはページキャッシュに載った状態。計測器は小さい C 親プロセスから `wait4` で子の最大 RSS を取得した。
- `Crystal scan` は再利用する 65,536 個の `Int32` バッファで全値を読み足す。`Rust C API scan` は同じ大きさのバッファに `d4_file_read_values` で読み足す。`Rust CLI stat` は `d4tools stat -t 1 -s sum`。各経路のアルゴリズムは異なる。特に C API は Rust の最速経路を意味せず、CLI は全値をアプリケーションに渡さず集計する。
- `point` は同じ擬似ランダムな 4,096 点をそれぞれ公開 API で読む。`write` は 65,536 値ずつ公開 API に渡す。RSS にはプロセス・マッピング・実行環境が含まれ、GC ヒープ量そのものではない。

## 読み出し

| 内容 | D4 サイズ | Crystal 走査 | Rust C API 走査 | Rust CLI 総和 | Crystal 最大 RSS | Rust CLI 最大 RSS |
|---|---:|---:|---:|---:|---:|---:|
| 主テーブル 8 Mb | 2.9 MiB | 68 ms | 49 ms | 19 ms | 2.6 MiB | 7.5 MiB |
| 主テーブル 64 Mb | 22.9 MiB | 518 ms | 422 ms | 134 ms | 2.7 MiB | 27.7 MiB |
| 主テーブル 256 Mb | 91.6 MiB | 2,062 ms | 1,565 ms | 573 ms | 2.6 MiB | 96.3 MiB |
| 辞書外の値 1%・8 Mb | 3.6 MiB | 75 ms | 54 ms | 20 ms | 3.4 MiB | 8.3 MiB |
| 二次テーブル中心 1 Mb | 9.5 MiB | 37 ms | 13 ms | 9 ms | 6.7 MiB | 14.4 MiB |
| 二次テーブル中心 5 Mb | 47.7 MiB | 197 ms | 54 ms | 35 ms | 6.7 MiB | 52.4 MiB |
| 二次テーブル中心 20 Mb | 190.7 MiB | 678 ms | 203 ms | 138 ms | 6.7 MiB | 195.5 MiB |

主テーブル 256 Mb では Crystal は Rust C API の **1.32 倍**、Rust CLI の **3.60 倍**の時間を要した。二次テーブル中心 20 Mb ではそれぞれ **3.34 倍**と **4.90 倍**。Crystal の `GC.stats.total_bytes` の増加量は、主テーブル 8→256 Mb で約 **340 KiB のまま**、二次テーブル 1→20 Mb で約 **4.5 MiB のまま**だった。これはこのストリーミング処理での値で、任意の API や同時実行を保証するものではない。

4,096 点の主テーブル読み出しは、8 Mb で Crystal **18.4 ms / Rust C API 1.36 ms**、64 Mb で **24.2 ms / 2.13 ms**。Crystal 側は 4,096 点あたり約 **5.18 MiB** を GC に割り当てている。この経路は速度も割り当ても改善の余地が大きい。

参考として、Rust リポジトリ添付の `hg002_full_no_cov.d4` の染色体 `1` の先頭 64 Mb を 1 回ずつ測ると、全て 0 で、Crystal 39 ms、Rust C API 495 ms、Rust CLI の領域総和 3.5 ms だった。ゼロ優勢・幅ゼロの辞書では処理経路が大きく変わる。合成ファイルの比率を全データに当てはめられない具体例である。

## 書き込み

| 内容 | Crystal | Rust C API | 倍率 | Crystal 最大 RSS | Rust 最大 RSS | 出力サイズ Crystal / Rust |
|---|---:|---:|---:|---:|---:|---:|
| 値が毎塩基変わる主テーブル 8 Mb | 4,698 ms | 80.6 ms | **58 倍** | 2.7 MiB | 5.1 MiB | 3,002,072 / 3,002,568 bytes |
| 辞書外値が交互に出る 1 Mb | 621 ms | 26.1 ms | **24 倍** | 2.7 MiB | 4.2 MiB | 10,004,504 / 10,002,312 bytes |

Crystal の `Writer#write_values` は各塩基を run として処理し、値が変わるたびに一時ファイルへ書き出す。完成時にその run を走査し直して主テーブル・二次テーブルを組み立てる。今回のように値が頻繁に変わる入力は、この設計の弱点を露出する。連続した同値区間の多い実データでは倍率が変わるため、この 24～58 倍を一般化しない。それでも **書き込みは現時点で最も重大な性能上の課題**である。

## 10 GiB への概算と限界

測ったのは最大 91.6 MiB の主テーブルと 190.7 MiB の二次テーブルであり、10 GiB の実ファイルを測ったわけではない。仮に**主テーブルの符号化密度・CPU 時間/バイト・温まったページキャッシュが同じ**なら、91.6 MiB を 10 GiB に比例拡大すると、連続総和は Crystal 約 **3.8 分**、Rust CLI 約 **1.0 分**となる。これは CPU 部分の概算にすぎない。10 GiB はこのホストの空き RAM を超え、実際にはストレージ読み出し・キャッシュミス・圧縮率・染色体数・並列化で大きく変わる。さらに「処理が 10 GiB のメモリを消費した」という観察だけから、ファイルが 10 GiB だったと仮定することはできない。

メモリ面では、これらの API の Crystal 走査は入力サイズにほぼ依存しなかった。Rust 側の RSS はファイルサイズとともに増え、Rust の主テーブル実装がメモリマップを使うこととも整合する。ただし RSS は GC ヒープや匿名メモリの量ではなく、Rust の「10 GiB」が何に由来するかはユーザーの実際の処理と `/proc/<pid>/smaps_rollup` 等で切り分ける必要がある。Crystal でも `values` による全領域の配列化、多数領域の同時保持、インデックス構築、キャッシュ設定次第でメモリは増える。

## 計測中に見つけて修正した問題

1. Crystal の `.stab` 親ディレクトリのサイズが 512 バイトと記録されていた。Rust のマップされた読み取りは子ストリームの範囲でパニックした。子ストリームを含む全サイズに修正し、Rust 0.3.11 の CLI と C API が Crystal 作成ファイルの総和を読めることを確認した。
2. 辞書の最終コード（例: `0...8` の `7`）を余計に二次テーブルへ書いていた。Rust と同様、辞書外の値のみ退避するよう修正した。8 Mb の例では Crystal の出力が約 13.0 MB から約 3.0 MB に縮小し、Rust が読み取れる。
3. 回帰 spec を追加。`crystal spec --single-module`: **32 examples, 0 failures**。Ameba と Crystal format check も通過。HTTP の spec はローカル socket を許可する環境で実行した。

## 次の最適化対象

1. `Writer#write_values` の密な入力は、run ごとのファイル書き込みを避け、固定サイズのパック済みバッファと、辞書外値のみの別ストリームへ流す経路を検討する。ここで大きな速度改善が期待できるが、断言するには実装後の同一条件での再測定が必要。
2. `Track#value` は 1 点ごとに Region、Scanner、二次ストリーム探索用オブジェクト等を作る。主テーブルだけで確定できる場合の短い経路や、複数点をまとめて読む API 内部経路を試し、GC 割り当てと精度を検証する。
3. 実際の WGS D4 について、ローカル連続走査・離れた領域の多数参照・索引あり/なし・書き込みを、同じデータ・同じ出力で比較する。10 GiB のメモリ消費を再現する操作を分離する。

再現用の `bench/compare.cr`、`bench/compare.c`、`bench/measure.c`、`bench/run_comparison.py`、`bench/run_write_comparison.py` と全測定値の JSON は同梱のソースにある。ビルド例: `crystal build --release bench/compare.cr -o /tmp/d4-crystal-compare`、`gcc -O3 -I<d4binding include> bench/compare.c -L<d4binding lib> -Wl,-rpath,<d4binding lib> -ld4binding -o /tmp/d4-rust-compare`、`gcc -O2 bench/measure.c -o /tmp/d4-measure`。配布された Rust ライブラリ・CLI の配置は各自の環境に合わせて指定すること。

## 追試: 処理方法を変えた場合（同日）

以下も同じホストで、初回を除く3回の中央値と子プロセスの最大 RSS。配列化は `D4::ReadOptions.new(max_materialized_bytes: 512 MiB)` を明示した（通常の上限は 64 MiB）。C API 側は同数の `Int32` を `malloc` した。結果の総和は一致した。

| 条件 | Crystal 時間 / 最大 RSS | Rust C API 時間 / 最大 RSS | Rust CLI 時間 / 最大 RSS |
|---|---:|---:|---:|
| 8 Mb を配列に全件展開 | 88 ms / 33 MiB | 65 ms / 36 MiB | 対象外 |
| 64 Mb を配列に全件展開 | 691 ms / 247 MiB | 498 ms / 269 MiB | 対象外 |
| DEFLATE 圧縮・二次テーブル 1 Mb の総和 | 48 ms / 3.8 MiB | 134 ms / 14 MiB | 28 ms / 16 MiB |
| DEFLATE 圧縮・二次テーブル 5 Mb の総和 | 235 ms / 3.9 MiB | 596 ms / 59 MiB | 122 ms / 61 MiB |
| 64 Mb を64領域に分けて集計・1 worker | 601 ms / 3.4 MiB | 対象外 | 139 ms / 28 MiB |
| 同上・4 workers | 243 ms / 4.6 MiB | 対象外 | 50 ms / 28 MiB |

**配列化すると両者とも出力配列のサイズに比例してメモリを消費し、省メモリ差は小さくなった。** 圧縮データでは Crystal の方が Rust C API の値読み出しより速かったが、最適化された Rust CLI の総和より遅い。Crystal の圧縮 5 Mb の走査は、最大 RSS こそ約4 MiBでも、GC 累積割り当ては約 **106 MB** あった。GC 言語では最大 RSS だけで負荷を評価できない。

SUM 索引付き二次テーブル 5 Mb の総和は、Crystal 作成の索引で Crystal **6.96 ms / 4.3 MiB**、Rust 作成の索引で Rust CLI **6.16 ms / 8.1 MiB**だった。それぞれの索引なしでは Crystal **175 ms**、Rust CLI **39 ms**。索引利用時には速度差が大きく縮む。ただし **同一の索引付き D4 での相互比較ではない**。現状、Rust が作成した索引を Crystal が開くとサイズ不一致、Crystal が作成した索引を Rust CLI が使うとパニックする。索引の相互運用性は未解決であり、実データでの運用上の欠陥として別途修正が必要。

この追試から、先の「Crystal は遅いが省メモリ」を全条件へ一般化するのは誤り。ストリーミング、配列化、圧縮、並列化、索引、点参照、書き込みを別々に評価する必要がある。特にユーザーの処理で 10 GiB を消費する操作がどれかを特定しない限り、そのメモリ差の予測はできない。
