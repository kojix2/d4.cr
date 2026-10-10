# d4.cr: 純Crystal実装のAPI・実装計画

作成日: 2026-10-09  
改訂: 2026-10-09。GCへの割り当て負荷、結果の所有権、集計状態・worker・索引の再利用を再検討。  
型選択の改訂: 利用者の指定により、独自型は原則class。structは実測で明確な効果を確認した場合のみ採用する。  
状態: 設計案。公開APIの契約を先に確定し、段階的に実装する。  
対象: 添付されたd4-formatのRustライブラリ機能と、その利用に必要なCrystal API。

## 1. 基本方針

D4の形式処理をCrystalで実装し、libd4・d4binding・Rustのランタイムを不要にする。既存d4.crのAPI互換は必須にしない。Rustの型やC関数を移植するのではなく、同じファイルを読み書きでき、主要な機能をCrystalらしく利用できるライブラリを作る。

「純Crystal」はD4のコンテナ、辞書、一次・二次テーブル、インデックス、走査、統計処理をCrystalで実装するという意味とする。OSのファイル操作やCrystal標準ライブラリのDEFLATE実装に伴うシステムライブラリまで排除する意味ではない。標準の圧縮実装はzlibに依存するため、外部Cライブラリを一切使わない構成は別要件である。独自DEFLATEエンジンは本計画の必須項目にせず、Codec境界で交換可能にする。

推奨する最低Crystalバージョンは1.21。CPU並列処理にはExecution Contextsを使う。古いバージョン用の並列ランタイム分岐を最初から増やさない。バージョンを下げる場合は、直列実装との共通部分を残し、実行器のみを別実装にする。

| 設計判断 | 採用案 |
|---|---|
| 読み取り | `D4::File`がコンテナを所有し、`D4::Track`がトラックのデータAPIを提供 |
| 単一トラックの使いやすさ | `File`から選択済みTrackへの薄い委譲を提供 |
| 書き込み | `D4::Writer`。メタデータは作成時に固定 |
| 座標 | 公開される座標・長さは`Int64`。整数引数を検証し、形式境界で`UInt32`へ変換 |
| 保存値 | 常に`Int32`。実数へのスケーリングは明示的なビュー |
| 領域和 | 一染色体内では正確な`Int64`。既存Float64インデックスも精度条件を確認して使用 |
| 走査 | ブロックありの`each_*`と、ブロックなしのIterator |
| 大量処理 | ブロックデコード・バッファ再利用・領域バッチ・区間単位集計 |
| 検索状態 | Iteratorごとに独立。Fileに共有のゲノムカーソルを置かない |
| 並列処理 | 明示的なworkers、独立状態、決定的な結果順序、制限付きキュー |
| GCへの負荷 | 原則class。借用buffer・scratch/stateの再利用を優先し、structは実測で採否を決める。累積割り当ても測る |
| テスト | メモリSource、低速参照実装、Rustとの相互運用、障害注入を分離 |

以下のコードはAPI案の使用例であり、現在のd4.crで動くコードではない。シグネチャ表は契約を示すもので、コンパイル済みのヘッダではない。

## 2. 対象機能と実装範囲

Rustの`d4`・`d4-framefile`を中核範囲とする。`d4tools`の周辺機能は、ライブラリに必要なものと、外部フォーマット連携を分けて扱う。

| Rust側の機能・位置 | Crystal側の対応 | 導入段階 |
|---|---|---|
| Framefileのdirectory/blob/linked stream | 内部`Format::Container`・Directory・Blob・FrameStream | A/B |
| Header・Chrom・Dictionary | Metadata・Chromosome・Dictionary | A/B |
| BitArray primary table | ブロック単位のBitDecoder・BitEncoder | A/B |
| SparseArray/RangeRecord secondary table | SecondaryReader/Writer・RangeRecordCodec | A/B |
| 無圧縮・DEFLATE・先頭フレームの例外処理 | Compressionと内部Codec | A/B |
| D4TrackReader・ゲノム領域読み取り | Track・each_value・each_interval・read_values_into | A |
| D4FileBuilder/Writer | D4.create・Writer | B |
| トラック列挙・名前付きトラック・階層 | File.track_names・track・each_track | A |
| D4MatrixReader・multi-track scanning | Matrix・再利用可能な行バッファ・トラック別集計 | C |
| local streaming・Read+Seek | LocalSource・IOSource・Source抽象 | A |
| HTTP Range・remote streaming | HTTPSource、有限キャッシュ、部分読み取り | D |
| mapped I/O | 任意のMappedSource。公開APIを変えない最適化 | E |
| SecondaryFrameIndex | SFIの読み書き・索引付き二次テーブル検索 | D |
| DataIndex<Sum> | SumIndex、端点補完付きの正確なsum | D |
| Task/TaskPartition/TaskContext | 型付きReducer・領域バッチ・並列実行器 | C/E |
| Sum/Mean/ValueRange | sum・mean・minmax・summary | C |
| Histogram/PercentCov | Histogram・Coverage。塩基数で重み付け | C |
| VectorStat | Matrix.aggregateによるトラック別統計 | C |
| reader.split・writer.parallel_parts | 内部分割計画・明示的なpartitioned writer | E |
| D4FileMerger | D4.merge・トラック選択付きコピー | D |
| 辞書ファイル・BAMからの辞書推定 | Dictionary.read・汎用Sampler、アラインメント側はアダプタ | C/F |
| bedGraph・統計結果の書き出し | 任意の`d4/bedgraph`・IOベースの入出力 | F |
| BAM/CRAM/SAM・BigWig変換 | 外部入力のアダプタ契約・将来の別shard | F |
| d4toolsのplot/server/framedump | 描画・HTTPサーバーは中核外。形式診断は任意のCLI | F |

段階Fは任意拡張であり、BAM/CRAM/BigWigパーサーを完成済みと扱わない。特に`depth_profiler`はRust側でもd4-htsに依存する。対応能力は入力アダプタと辞書推定により確保するが、外部フォーマットのパーサー自体は中核と別の成果物である。A〜Eが完了するまで「Rust版の主要ライブラリ機能を実装済み」とは呼ばない。

## 3. 公開型

| 型 | 責務 |
|---|---|
| `D4::File` | Sourceの寿命、コンテナ、トラック列挙、既定トラックの選択 |
| `D4::Track` | 一つのトラックのMetadataと読み取り操作。共有カーソルを持たない |
| `D4::ScaledTrack` | Trackを参照し、denominatorを適用したFloat64の読み取りを提供 |
| `D4::Matrix` | 同じ座標系の複数Trackを列として読む |
| `D4::ScaledMatrix` | 列ごとのdenominatorを適用するMatrixの読み取りビュー |
| `D4::Writer` | 一つのトラックを持つ新規ファイルを作る |
| `D4::PartitionWriter` | 予約済みの書き込み領域に限定したWriter |
| `D4::Chromosome` | 不変なname・size |
| `D4::Region` | 不変なchromosome・start・stop。値を持たない |
| `D4::Interval(T)` | 不変なstart・stop・value。染色体は走査の文脈に属する |
| `D4::Metadata` | 染色体の宣言順、Dictionary、denominator、形式情報 |
| `D4::Dictionary` | 範囲辞書または値リスト辞書の内容とbit_width |
| `D4::Summary` | length・sum・mean・min・max |
| `D4::Histogram` | 有限の値範囲の塩基数、below・above |
| `D4::ExactHistogram` | 観測値ごとの塩基数。明示的なdistinct-value上限付き |
| `D4::Coverage` | thresholdごとのcount・fraction |
| `D4::HistogramTails` | into版のbelow・aboveを返す結果class |
| `D4::RegionResult(T)` | 入力のindex・Region・集計結果 |
| `D4::ValueBlock(T)` | startと所有されたSlice(T)。保持可能なデコードblock |
| `D4::Row` | positionと所有されたArray(Int32)。便利なMatrix列挙用 |
| `D4::ScaledRow` | positionと所有されたArray(Float64)。ScaledMatrix列挙用 |
| `D4::BinSummary` | RegionとSummary。ビンの範囲・値を一緒に返す |
| `D4::DictionaryRecommendation` | 推定Dictionary、推定サイズ、サンプリング条件 |
| `D4::TrackInput` | merge用のpathと明示的なtrack名 |
| `D4::ValidationReport` | 検査対象・深さ・検出した問題 |
| `D4::ReadOptions` / `WriteOptions` | 不変の設定。必須メタデータとは分離 |
| `D4::Source` | バイト位置指定の読み取り境界。高度な利用者とテスト用 |

Fileを`IO`のサブクラスにはしない。D4の読み取り単位はバイトではなくゲノム値であり、`IO#read`との意味の衝突を避ける。FrameStreamやbedGraph入出力など、バイトストリームであるものだけにIOの性質を持たせる。

Metadata・DictionaryのArrayやHashをそのまま変更可能な参照として返さない。列挙を基本とし、配列を返すメソッドはコピーを返す。内部では一つの辞書・染色体名を共有し、デコーダごとに巨大なコピーを作らない。

小さな不変型のconstructorは通常のCrystalのnewを使う。Chromosomeは`new(name, size)`、Regionは`new(chromosome, start, stop)`、Interval(T)は`new(start, stop, value)`。座標はconstructorでも検証し、Intervalのvalue型はRaw/Scaled APIでそれぞれInt32/Float64に固定する。Metadataはdictionary・denominator・chromosome_countと染色体列挙を提供する。RowやValueBlockの内容は所有するが、利用者による変更が元のTrackへ書き戻されることはない。

### 3.1 原則class、structは実測による例外

独自の公開型・内部型は原則classにする。Chromosome、Region、Interval(T)、Summary、BinSummary、RegionResult(T)、ValueBlock(T)、Row、ScaledRow、HistogramTails、ScaledTrack、ScaledMatrixも、実測前はclassとする。「小さい」「不変」「数値だけ」「GC allocationを減らせそう」という理由だけでstructを選ばない。

File、Track、Matrix、Writer、Source、Metadata、Dictionary、独立Iterator、長寿命の内部ScanWorkspaceもclassにする。所有が必要な公開結果には結果ごとの割り当てがあり得る。そのコストを隠さず、内部走査では結果objectを介さず、数値bufferやscalarを直接処理する。共有できる不変ビューは繰り返し作らず、必要に応じて一度作って再利用する。

structの採用には、同じ意味・出力・所有権のclass実装と比較したrelease buildのベンチマークを必須にする。実際のcall chain、Arrayへの格納、返却、copy、capture/escape、並列利用を含め、throughput/latency、累積allocation、GC時間、peak RSSを確認する。allocationが減っただけでは採用せず、実際の処理性能に再現可能で明確な改善があり、主要な他経路に大きな悪化がない場合だけ採用する。結果・対象型・適用範囲を記録し、型ごとに判断する。

まだテストしていないstruct案は採用済みの設計にしない。copyやboxingがどこで起きるかは実際の型・compiler・利用経路で確認し、stack配置を一般的な保証として使わない。この方針は独自型のclass/struct選択に適用する。既存のInt/Float/Slice/TupleなどCrystal標準型はそのまま利用し、独自structを使う口実にはしない。

## 4. 座標、値、空領域の契約

### 4.1 座標

- 全操作を0始まり・終端を含まない`[start, stop)`で統一する。
- 公開の座標・長さは`Int64`。通常のリテラルや`UInt32`などの整数引数も受け付けるが、範囲検証前に狭い型へ変換しない。
- 対応する染色体長は`0..UInt32::MAX`。Rustでusizeとして表現される箇所があっても、二次テーブルや索引は32bit座標を使うため、これを超える染色体は黙って切り詰めず`UnsupportedFeatureError`にする。
- バイトoffsetは`Int64`。offset・size・積・加算はオーバーフローを検査する。
- `0 <= start <= stop <= chromosome.size`を満たす領域だけを受け付ける。
- point読み取りでは`position < size`。空領域では`start == stop == size`も合法。
- 不明な染色体は例外。範囲の自動切り詰めやchr接頭辞の自動変換はしない。

Regionを使わず`chromosome, start, stop`を渡す入口を残す。繰り返し利用やバッチにはRegionを使う。

```crystal
region = D4::Region.new("chr1", 1000, 2000)
same   = D4::Region.new("chr1", 1000...2000)
```

有限な整数Rangeにも対応する。`1000..1999`は`1000...2000`に正規化する。inclusive終端への+1は広い型で検査する。beginless/endless Rangeは最初の公開APIには含めず、`stop: nil`による染色体終端指定と混同しない。

### 4.2 値と空領域

| 操作 | Raw Track | ScaledTrack | 空領域 |
|---|---|---|---|
| value | Int32 | Float64 | pointには空領域なし |
| values | Array(Int32) | Array(Float64) | 空配列 |
| each_value | Iterator(Int32) / ブロック | Iterator(Float64) / ブロック | 要素なし |
| each_interval | Interval(Int32) | Interval(Float64) | 要素なし |
| sum | Int64 | Float64 | 0 / 0.0 |
| mean | Float64? | Float64? | nil |
| minmax | Tuple(Int32, Int32)? | Tuple(Float64, Float64)? | nil |
| coverage count | Int64 | 初版はRawのみ | 0 |
| coverage fraction | Float64? | 初版はRawのみ | nil |

HistogramとCoverageのcountは区間数ではなく塩基数とする。D4には欠損値の共通表現を仮定せず、保存値0を欠損扱いしない。将来の欠損マスクは別の明示的な機能にする。

## 5. ファイルを開く、トラックを選ぶ

```crystal
require "d4"

D4.open("depth.d4") do |file|
  puts file.chromosome_size("chr1")
  puts file.mean("chr1", 1000, 2000)
end

D4.open("cohort.d4") do |file|
  puts file.track_names
  tumor = file.track("tumor")
  puts tumor.mean("chr1", 1000, 2000)
end

D4.open("cohort.d4", track: "tumor") do |file|
  puts file.mean("chr1", 1000, 2000)
end
```

| メソッド | 戻り値・契約 |
|---|---|
| `D4.open(path : String \| Path, *, track : String? = nil, options : ReadOptions = ...)` | File |
| 同じ引数にブロック | ブロック結果を返し、ensureでclose |
| `D4.open(io : IO, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ...)` | seek可能なIOを借りる。trueの場合だけ所有 |
| `D4.open(source : Source, *, sync_close : Bool = false, ...)` | 明示的なSourceを借りる |
| `File#track_names` | Array(String)。コンテナ探索順、コピー |
| `File#each_track` | ブロックありなら列挙、なしならIterator(Track) |
| `File#track(name)` / `track?(name)` | Track / Track? |
| `File#default_track` | 明示選択済み、または唯一のTrack。それ以外はTrackSelectionError |
| `File#close` / `closed?` | 冪等なclose / Bool |

単一トラックなら自動的に既定トラックにする。複数トラックでもFile自体は開けるが、未選択のまま`file.values`などを呼ぶとTrackSelectionErrorにする。探索順で最初のトラックを選ばない。

Fileのデータ操作はdefault_trackに委譲する。アルゴリズムはTrackに一度だけ実装する。委譲するのはmetadata・chromosome関連、基本読み取り、統計、scaled、aggregate関連の安定した操作だけである。

トラック名はコンテナ内の相対パス。単一トラックがrootにある場合の名前は空文字列`""`とする。`track("a/b")`を受け付けるが、`.`・`..`や絶対パスを拒否する。`file.d4:track`やURLのfragmentにトラック指定を埋め込まず、引数を分ける。

Track・Matrix・ScaledTrack・IteratorはFileに従属するビューであり、個別のファイルcloseを提供しない。Fileが閉じた後のデータアクセスはClosedError。Iteratorをブロック外へ持ち出しても寿命は延長しない。メタデータのコピーはclose後にも利用できる。

任意IOがseekを実装しているとは限らない。開く段階でseek/tellと長さ取得の可否を検証し、unsupportedなIOにはNotSeekableErrorを返す。初版では巨大な非seek IOを暗黙にメモリへ読み込まない。

## 6. Trackの読み取りAPI

以下は`chromosome, start = 0, stop = nil`形式と`Region`形式の両方を持つ。内部では一つの検証済み領域へ正規化する。

| メソッド | 型・意味 |
|---|---|
| `metadata` | Metadata |
| `each_chromosome` | Chromosomeをブロック/Iteratorで列挙 |
| `chromosomes` | 宣言順のArray(Chromosome)、コピー |
| `chromosome(name)` / `chromosome?(name)` | Chromosome / Chromosome? |
| `chromosome_size(name)` / `chromosome_size?(name)` | Int64 / Int64? |
| `has_chromosome?(name)` | Bool |
| `value(chromosome, position)` | Int32。一点のランダム読み取り |
| `values(region)` | Array(Int32)。明示的な全件確保 |
| `each_value(region)` | ブロックありならNil、なしならIterator(Int32) |
| `each_interval(region)` | ブロックありならNil、なしならIterator(Interval(Int32)) |
| `read_values_into(chromosome, start, buffer : Slice(Int32))` | Int32。実際に埋めた要素数 |
| `each_block(region, *, block_size : Int32 = 65_536)` | 所有されたValueBlockをブロック/Iteratorで返す |
| `scan_values(region, buffer : Slice(Int32), &)` | 再利用バッファとblock_startをブロックへ渡す。Nil |
| `scaled` | ScaledTrack |

`values`は便利な入口として残すが、ReadOptionsのmaterialization上限を超える場合はAllocationLimitErrorにする。染色体長が配列の添字上限を超える場合も事前に拒否する。呼び出し側はストリーミングを選ぶか、明示的に上限を変更する。

valuesは最終的なArrayを一度確保して直接埋める。各blockのArrayを作ってconcatしたり、read_values_intoのために毎回新しいSlice(size)を作ったりしない。既存bufferのSlice viewは新しいデータ領域を確保せずに使えるが、Slice.new(size)はheapを確保する。この二つを同じ「Sliceなので低割り当て」と扱わない。

`read_values_into`は染色体をまたがない。終端付近では部分充填し、返したcountより後ろのバッファは変更しない。startが染色体終端なら0。途中の破損やI/OエラーをEOFとして返さない。

```crystal
D4.open("depth.d4") do |file|
  buffer = Slice(Int32).new(65_536)
  count = file.read_values_into("chr1", 1000, buffer)
  puts buffer[0, count].sum(0_i64)

  file.each_interval("chr1", 1000, 2000) do |interval|
    puts interval if interval.value >= 30
  end

  # 独立したIterator。片方の読み取りで他方の位置が変わらない。
  a = file.each_value("chr1", 1000, 2000)
  b = file.each_value("chr2", 1000, 2000)
  puts a.next
  puts b.next
end
```

### 6.1 所有と借用

`each_block`のValueBlock(Int32)はstartとSlice(Int32)を所有する。保持しても次の反復で上書きされない。これは各ブロックのメモリ確保を伴う入口であり、最高性能用には`scan_values`を使う。

`scan_values`は呼び出し側バッファの有効部分を渡し、次の反復で上書きする。渡されたSliceを保持・別workerへ転送したい場合は、利用者がコピーする。API名とドキュメントで借用を明示する。空バッファ・block_size<=0はArgumentError。

ブロックありのscan/each経路は直接yieldする。ブロックを保持するProcやIterator chainを各要素で作らない。ブロックなしIteratorは一走査に一つ作り、デコーダ・scratchを保持してnextごとのQueryPlan/Region/lease classの作成を避ける。valueの一点取得を公開each_valueのIteratorを新規作成して実装しない。内部では検証済みのscalar座標と、再利用するCursor classを使う。

`each_interval`は一次・二次テーブルを統合した最終値の最大同値区間を返す。検索領域内へ切り詰め、ゼロを含め、デコードブロックや物理レコード境界で同値区間を分断しない。表示用Intervalと物理RangeRecordは別物である。

Iteratorの構築は領域検証までに留め、最初のnextでデータを読む。途中のI/Oエラー・破損はnextから例外として伝える。再走査には新しいIteratorを作る。Iterator自身を複数workerで共有しない。

## 7. denominatorと正確な集計

Raw APIは辞書から復号された保存整数を返す。denominatorを適用するAPIをビューとして分け、戻り値をファイル内容によってUnion型にしない。

```crystal
D4.open("signal.d4") do |file|
  raw = file.value("chr1", 1000)          # Int32
  value = file.scaled.value("chr1", 1000) # Float64
  mean = file.scaled.mean("chr1", 0, 1000)
end
```

実数値は`stored_value.to_f64 / denominator`。denominatorは有限かつ正のFloat64とする。ScaledTrackではmean/minmax/sumと読み取り方法を同じ命名で提供する。Histogram・Coverageの実数threshold版は初版に含めず、整数thresholdの解釈を曖昧にしない。

ScaledTrackのread_values_into/scan_valuesはSlice(Float64)、each_blockはValueBlock(Float64)を使う。RawのReducerを任意の実数Reducerへ自動変換しない。初版のScaledTrackは基本読み取りとsum/mean/minmaxに限定し、summary/histogram/coverage/汎用aggregateはRawで実行して必要な値を明示的にスケールする。結果型が違う機能を同名の委譲で無理に共通化しない。

Scaledのinto/scanではdecodeした整数を呼び出し側のFloat64 bufferへ直接変換する。blockごとにRaw Arrayを作り、そのmapで別のFloat64 Arrayを作る経路は使わない。二次レコードやpacked byteのscratchはworkspace内で再利用する。

一つの領域は一つのUInt32長の染色体に属するため、Int32値の合計はInt64に収まる。区間集計では`value.to_i64 * length`を使い、長さと乗算の型を揃える。染色体をまたぐ全ゲノムの和は別のAPIであり、本計画ではInt64保証を流用しない。必要な場合はInt128の集計器を追加する。

### 7.1 既存sum indexとの精度互換

RustのTask::SumはInt64だが、保存されるDataIndex<Sum>はFloat64である。この違いを公開APIへ漏らさず、Raw sumは常にInt64を返す。

標準の65,536 bpブロックは、Int32の値を加算しても絶対値が最大2^47なので、整数和はFloat64でも正確に表現できる。索引の各ブロックを読み、有限性・整数性・境界を検証してInt64へ戻し、Int64で合算する。複数ブロックを先にFloat64で合計しない。

一般のgranularityについては`block_length * 2^31 <= 2^53`を安全性の十分条件として用いる。条件外では、Float64が整数に見えても正確だった証明にはならない。Autoは走査へ戻し、RequireはIndexPrecisionErrorとする。単純なFloat64→Int64キャストだけでは済ませない。

インデックスはデータが不変である前提で使用する。外部プロセスによる書き換えはサポートしない。古い索引の正当性はヘッダ検査だけでは保証できず、後述のdeep validationでデータと照合する。

## 8. 統計、ヒストグラム、ビン集計

| メソッド | 結果 | 意味 |
|---|---|---|
| `sum(region, *, index : IndexPolicy = Auto)` | Int64 | 保存値の和 |
| `mean(region, *, index : IndexPolicy = Auto)` | Float64? | 和 / 塩基数 |
| `minmax(region)` | Tuple(Int32, Int32)? | 最小・最大 |
| `summary(region)` | Summary | 一回の走査でlength/sum/min/max。meanは算出 |
| `histogram(region, *, value_range)` | Histogram | 有限範囲の整数値別の塩基数と範囲外count |
| `histogram_into(region, counts : Slice(Int64), *, value_range)` | HistogramTails | countsを0に初期化して直接加算。below/aboveの結果classは一呼び出しに一つ |
| `exact_histogram(region, *, max_values : Int32 = 4096)` | ExactHistogram | 全観測値を保存、上限を超えたら例外 |
| `coverage(region, *, thresholds)` | Coverage | threshold以上の塩基数と割合 |
| `coverage_into(region, thresholds : Slice(Int32), counts : Slice(Int64))` | Int64 | countsを0にして直接加算。戻り値は母数となる領域長 |
| `each_bin(region, *, bin_size)` | Iterator(BinSummary) / ブロック | 固定幅の連続ビン。最終ビンは短縮 |
| `sample(region, *, bins : Int32 = 256)` | Array(BinSummary) | 領域を最大bins個に均等分割、summaryを返す |

value_rangeには有限な整数Rangeを使い、Histogramはstart/end/counts/below/aboveを提供する。countはInt64。指定範囲全体が大きすぎれば集計予算に基づき事前に拒否する。負の値も普通のInt32として数える。

histogram/coverageは保持可能な独立した結果bufferを返す。内部scratchを結果として貸し出し、次の集計で上書きする実装は不可。繰り返し呼び出す解析にはinto版を用意し、同じcount bufferを再利用できるようにする。histogram_intoのcounts.sizeはvalue_rangeの値数、coverage_intoのcounts.sizeはthresholds.sizeと一致させる。thresholdsとcountsは処理中に外部変更せず、scan/outputのscratchとaliasさせない。

coverage_intoは新しいfraction配列を返さない。fractionはcount/返されたlengthで利用者が算出する。入力threshold順の直接比較を基準実装とし、ソート用Arrayの毎回確保を要求しない。HistogramTailsはbelow/aboveのInt64だけを持つclassであり、into版はcount配列の再確保を避けるが、全allocationがゼロという契約ではない。into版は呼び出し側の所有bufferを変更するため、入力検証は可能な限り初期化より前に行い、途中のI/O失敗時はbufferを未完成として扱う。

ExactHistogramは観測した整数値からcountへのHashを保持する。異なる値が大量にあるデータで無制限にメモリを消費しない。上限超過時に値を黙って落とさない。

両Histogramは`quantile(q)`を提供し、整数値のnearest-rankで定義する。qは0..1、空ならnil。非空ではrankを`max(1, ceil(q * total_count))`とし、q=0は最小値、q=1は最大値になる。有限範囲Histogramにbelow/aboveがある場合はIncompleteHistogramErrorとし、完全な分布であるかのようにpercentileを返さない。ExactHistogramは全観測値に対して計算できる。Scaled値の分位点は整数分位点をdenominatorで割る。

CoverageのthresholdはInt32。`value >= threshold`を符号付き比較する。count/fractionは入力threshold順に返す。内部ではthresholdをソートして効率化しても、公開順序や重複thresholdを変えない。fractionは0..1であり、百分率は利用者が100倍する。

区間長Lのvalue VはsumへV*L、HistogramへL、Coverageへ条件成立時Lを加える。Intervalの個数を塩基数として数えない。Rust実装の境界条件や負値の扱いの不備は互換仕様にしない。

`sample`は表示用のmeanだけでなくmin/maxも返し、局所的なピークを保持できるようにする。整数除算の余りは先頭側のビンへ一塩基ずつ配り、全塩基を重複なく覆う。binsが領域長を超えたら領域長へ制限する。空なら空配列、bins<=0は例外。

ビンごとにvalueを一点ずつ取得しない。隣接ビンをまとめて走査し、利用可能なsum indexと端点処理を組み合わせる。結果の配列確保にはmaterialization上限を適用する。

## 9. 領域バッチと拡張可能なReducer

```crystal
regions = [
  D4::Region.new("chr1", 1000, 2000),
  D4::Region.new("chr1", 5000, 6000),
]

D4.open("depth.d4") do |file|
  results = file.aggregate(regions, D4::Reducers::Mean.new, workers: 4)
  results.each { |result| puts result.value }
end
```

API案:

```crystal
# Sは状態型、Rは結果型。実装時に型パラメータを明示する。
# 実際の入口はreducerの具体型Dを保持し、内部RunnerをD/S/Rで特殊化する。
# Reducer(S, R)は満たすべきプロトコルであり、値型をmoduleの箱に入れる指定ではない。
aggregate(regions, reducer, *, workers = 1) : Array(RegionResult(R))
each_aggregate(regions, reducer, *, workers = 1, batch_size = 256)
```

`aggregate`は有限入力の便利API。結果は入力順で、重複・重なり領域も独立した集計として返す。大きな入力には`each_aggregate`を使い、有限バッチだけを保持する。ブロックなしはIterator、ありは順にyieldする。巨大なregionリストを自動的にto_aしない。

初版のeach_aggregateは、次のバッチを要求された時点で計算し、そのバッチの仕事をjoinしてから結果をyieldする。yieldの間に結果待ちのバックグラウンド計算を残さない。利用者がIteratorを途中で放棄しても、満杯のChannelに送信するworkerが残り続ける設計にしない。より積極的なprefetchは明示的なclose/cancel可能なquery型を設計した後の追加とする。

joinするのはそのバッチの仕事であり、各バッチでcontext/Channel/Fiber/workspaceを作り直す意味ではない。並列実行器はFileのresource ownerが必要時に一度構築する有限のworker poolとして再利用し、File.closeで停止する。Matrixは参加するFileの一つの実行器を使い、関連Fileすべてのclose/cancelを監視する。Iteratorごとの無制限な常駐poolを作らない。

yieldの間にpoolのworkerは待機していてよいが、現在のqueryの借用buffer・Reducer状態・利用者Procを保持した未完了jobは残さない。結果はIteratorが所有する有限バッチにだけ保持する。仕事を終えたslotの参照を消し、Iteratorが放棄されたことでquery自体をpoolがrootし続けない。最大worker数・同時query数・queue容量はworkers要求と既存のbyte予算から有限値を決め、追加poolの無制限作成を禁止する。バッチごとの新しいCPU contextを低コストだと仮定しない。

Reducerの型付きプロトコル:

| 操作 | 契約 |
|---|---|
| `seed : S` | 領域・partitionごとに独立した初期状態を返す |
| `consume(state : S, start : Int64, stop : Int64, value : Int32) : S` | 同値区間を状態へ追加 |
| `merge(left : S, right : S) : S` | 隣接partitionの状態を結合 |
| `finish(state : S) : R` | 最終結果へ変換 |

Sum、Mean、MinMax、Summary、Histogram、Coverageを組み込みReducerとして実装する。具体型を不必要にAny/Reference/Boxへ消去しない。Unionやabstract dispatchが必ず割り当てると一般化せず、具体型を保持した経路をcompile/allocation specで確認する。Sum/Mean/MinMaxの独自stateは再利用するclass、または既存のscalar/Tupleで表現する。Histogramなどは再利用可能な数値bufferを参照するstate classとする。独自stateをstructに変える場合も3.1の実測条件を満たすこと。

consume/mergeが新しいHistogramやcount配列を毎回返す契約にはしない。状態の所有bufferをin-placeで更新して同じstateを返す実装を許す。組み込みのbufferを持つReducerには`reset(state : S) : S`を用意し、排他的に使い終えたstateをゼロクリアして再利用する。任意の利用者Reducerにresetを必須にはせず、再利用可能性を明示した追加プロトコルにする。

seedは最初に必要な独立状態を作る入口であり、全領域×全partitionに一斉にnewする指示ではない。進行中の領域だけにstateを割り当て、完了後に有限のpoolへ返す。mergeは排他的な左bufferへ加算できる。finishが保持可能なRを返す場合はstateのbufferをコピーまたは所有移譲し、そのbufferをpoolに戻して次の領域で変更しない。この出力コピーを避けたい利用者にはhistogram_into/coverage_intoを提供する。

並列化可能なReducerには結合の意味を明示する。順序依存のReducerは座標順にmergeし、任意順の結合を行わない。Float64の結合順はpartitionの座標順で固定する。浮動小数点結果の完全なbit一致を要求する統計には固定分割を使い、通常の検証では明示した許容誤差を使う。

同一Track内の近接・重複領域は、バッチ内でソートとactive-region走査によりデコードを共有する。ただし結果順は入力順へ戻す。同じソースに対するN件の独立seekを常にN回の完全な再走査へ落とさない。最適化前の直列Reducer実装をテスト用の参照経路として保持する。

共有decodeよりもstateの総量を優先する。batch_sizeだけでなくmax_active_statesとaggregate_state_bytesを検査する。Histogramなどで予算を超えるときはバッチ/同時partitionを小さくし、必要なら領域ごとの再走査を選ぶ。それでも一状態が収まらなければResourceLimitError。近接領域のscan共有のために全領域のHistogramを同時保持しない。

## 10. 複数トラックとMatrix

```crystal
D4.open("cohort.d4") do |file|
  matrix = file.matrix(["normal", "tumor"])
  buffer = Slice(Int32).new(4096 * matrix.column_count)
  rows = matrix.read_rows_into("chr1", 1000, buffer)

  # 同じRegionを各トラックで集計。列順はnormal、tumor。
  results = matrix.aggregate(
    [D4::Region.new("chr1", 1000, 2000)],
    D4::Reducers::Mean.new,
  )
end
```

| メソッド | 契約 |
|---|---|
| `File#matrix(names)` | 指定順のトラックからMatrixを作る |
| `Matrix.new(tracks : Enumerable(Track))` | 複数FileのTrackも利用可、Fileの寿命に従属 |
| `column_count` / `track_names` | Int32 / 列順の名前。異なるFileでは同名を許し、列indexで区別 |
| `read_rows_into(chromosome, start, buffer : Slice(Int32))` | 行数。row-major。buffer.sizeはcolumn_countの倍数 |
| `each_row(region)` | positionと所有された値配列を持つRowをブロック/Iteratorで返す |
| `scan_rows(region, buffer : Slice(Int32), &)` | startとrows個の借用row-major Sliceを渡す |
| `aggregate(regions, scalar_reducer, *, workers = 1)` | RegionResult(Array(R))。列順に一つの結果 |
| `aggregate_into(regions : Indexable(Region), scalar_reducer, output : Slice(R), *, workers = 1)` | Nil。領域×列のrow-major結果を既存bufferへ格納 |
| `scaled` | 列ごとのdenominatorを適用するScaledMatrix |

染色体名・長さ・宣言順を完全一致で検証する。暗黙のinner join・欠損列の0埋め・染色体の並べ替えはしない。異なる辞書やdenominatorは許す。空の列選択と同一Trackの重複指定はArgumentError。

`each_row`は使いやすいが、保存可能なRowのための配列確保を伴う。全ゲノム解析にはscan_rows/read_rows_intoを勧める。組み込み集計は各塩基でRowやArrayを作らず、ブロックまたは同値区間を直接処理する。

Matrix.aggregateの各領域にArray(R)を返す構造は、全結果を保持できる代わりに領域数に比例する配列割り当てを伴う。この構造は最適化だけでは取り除けないため、aggregate_intoを性能用の入口として追加する。output.sizeをregions.size*column_countと事前に照合する。Sum/Meanの数値結果や既存Tupleを使うMinMaxでは、結果を直接格納できる。Summaryなどの独自結果classや所有Histogramでは、列Arrayを省略しても結果object/bufferの割り当てが残る。classの参照をoutputへ格納することと、class instanceの割り当てを省くことを混同しない。呼び出し側が結果bufferを再利用する場合、各Rの所有権を別に管理する。

内部Matrix workspaceの行数は固定65,536ではなく、列数・出力型の幅・同時に必要なscratchからworker_buffer_bytes内へ計算する。row-major出力と全列分のcolumn-major作業bufferを常に二重に保持しない。外部提供bufferの容量は利用者の責任だが、ライブラリが作る作業bufferは別に制限する。

ScaledMatrixのread_rows_into/scan_rowsはSlice(Float64)を使い、列ごとのdenominatorを適用する。所有される行型は別のScaledRowとする。初版では汎用aggregateをScaledMatrixへ公開しない。Raw Matrix.aggregateのトラック別結果から、目的に応じてスケーリングする。

内部には複数列の同値境界を統合する走査を置き、RustのDataScanner/VectorStat相当を満たす。利用者の列間処理はscan_rowsで実装できる。汎用の列間Reducer公開は、まずこの走査で性能・所有権を確認してから追加する。Matrix全体の和を暗黙に一つのInt64へ合算しない。

## 11. 辞書とサンプリング

```crystal
range_dict = D4::Dictionary.range(0...128)
value_dict = D4::Dictionary.values([0, 10, 20, 100])
```

| 操作 | 契約 |
|---|---|
| `Dictionary.range(range)` | 連続範囲。終端の解釈は普通のRangeに従う |
| `Dictionary.values(values)` | 指定順がコード→値。勝手にソートしない |
| `Dictionary.read(io)` | 1行1整数の辞書ファイル。空行・不正値は位置付き例外 |
| `bit_width` / `size` / `kind` | Int32 / Int64 / DictionaryKind |
| `value_at(code)` | コードに対応する保存値。範囲外は例外 |
| `includes?(value)` | Bool |

書き込み辞書の要素数は2^K、K=0..31、値は重複しないInt32。範囲辞書のlow/highは形式のInt32ヘッダで表現可能なものに限定し、差は広い型で計算する。K=0を禁止しない。空辞書・重複値・不正な長さ・表現不能な境界はArgumentError。

範囲辞書はlow/highだけを保存し、2^K要素のArrayや値→コードHashを展開しない。値リスト辞書は一つのInt32 bufferを共有する。値→コードの逆引きHashはWriter/推定が必要なときだけ一度構築し、Readerや各Decoderに複製しない。公開Dictionary.valuesへの入力は構築時の一度だけコピーして所有し、以後の走査でコピーしない。

読み取りは実際のヘッダから辞書形式を保ったまま構築する。不正な辞書を勝手にパディング・ソートして別の対応にしない。添付Rustの値リスト辞書は作成経路によって検証が弱いため、読めることと正しい形式であることを区別し、曖昧な非2^K辞書はUnsupportedFeatureErrorまたはFormatErrorで報告する。相互運用対象の有効な辞書はfixtureで固定する。

一次テーブルの最大コードは例外参照用でもあり、対応する辞書値が有効な値である可能性もある。最大コードを見ただけで「必ず二次レコードがある」と決めつけない。二次値がなければ辞書側のfallbackを使う。K=0では一次データがなくても二次値を優先し、なければ辞書の唯一の値を使う。

`Dictionary::Sampler`は再現可能な明示的操作にする。seed、sample_bases、max_bits、max_valuesを設定し、値頻度と同値区間頻度から一次・二次の推定サイズを比較する。結果は`DictionaryRecommendation`としてdictionary・推定サイズ・使用したseedを返す。max_bitsの初期値は16、候補数とヒストグラムに予算を設ける。

入口は`Sampler.new(seed: ..., sample_bases: ..., max_bits: 16, max_values: ...)`とし、`recommend(track, regions: ...)`または`recommend_intervals(intervals)`でDictionaryRecommendationを返す。後者のInterval列は選んだサンプルだけを提供する契約とし、全入力を暗黙に蓄積しない。辞書推定後に同じSamplerを変更してWriterの辞書を変えることはできない。

推定には既存Track、提供されたInterval列、外部入力アダプタを使える。一回しか読めない入力をWriterが暗黙に二度読む設計にしない。推定してから作成するか、利用者が明示的に一時スプールを選ぶ。サンプリングから同値区間の端を切る場合、その頻度推定への影響を記録する。

## 12. 書き込みAPIと完了処理

```crystal
D4.create(
  "output.d4",
  chromosomes: {"chr1" => 1000, "chr2" => 2000},
  dictionary: D4::Dictionary.range(0...128),
  denominator: 1.0,
  default_value: 0,
  options: D4::WriteOptions.new(
    compression: D4::Compression.deflate(level: 5),
  ),
) do |writer|
  writer.write_values("chr1", 0, [1, 2, 3, 4, 5])
  writer.write_interval("chr1", 100, 200, 10)
  writer.write_interval("chr2", 0, 2000, 20)
end
```

| メソッド | 戻り値・契約 |
|---|---|
| `D4.create(path, *, chromosomes, dictionary = range(0...64), denominator = 1.0, default_value = 0, options = ...)` | Writer |
| 同じ引数にブロック | 正常終了でfinish、失敗でabort。ブロック結果を返す |
| `D4.create(io : IO, *, ..., sync_close = false)` | 書き込み・seek可能なIO。既存内容ありなら拒否 |
| `Writer#write_values(chromosome, start, values : Array(Int32) \| Slice(Int32))` | Int32。全要素成功、または例外 |
| `write_value(chromosome, position, value : Int32)` | Nil |
| `write_interval(chromosome, start, stop, value : Int32)` | Nil |
| `write_intervals(chromosome, intervals : Enumerable(Interval(Int32)))` | Int64。成功したInterval数 |
| `write_scaled_values(..., values, *, rounding : Rounding)` | Int32。denominatorを掛け、明示した丸めで量子化 |
| `write_scaled_interval(..., value, *, rounding : Rounding)` | Nil |
| `flush` | Nil。現在までのエンコード状態を排出。完成の意味ではない |
| `finish` / `close` | Nil。残りを埋め、索引・コンテナを完成させる。成功時のみfinished |
| `abort` | Nil。未完成の出力を破棄または無効化 |
| `closed?` / `finished?` | Bool |

作成時に染色体の宣言順・長さ・辞書・denominator・default_valueを固定し、最初のwrite後には変更させない。Hashは挿入順を使う。Array(Chromosome)とEnumerable(Chromosome)も受け付け、重複名を検証する。

逐次モードでは染色体の宣言順、各染色体の座標順を要求する。過去の染色体へ戻れず、重複・逆転・範囲外書き込みを拒否する。Interval列は明示された非重複区間として扱い、最後の区間の終端を推測しない。各呼び出しの前に検証できる範囲は検証し、書き込んでから範囲外を発見する状態を減らす。

未書き込みの先頭・隙間・末尾と省略した染色体はdefault_valueで埋める。これはWriterの論理契約であり、D4に独立したdefault_valueヘッダがあるという意味ではない。辞書コード0の値がdefault_valueと一致すれば一次テーブルの初期ゼロを利用できる。一致しなければ必要なbit patternまたは二次レコードを明示的に生成する。

辞書外のInt32値は二次テーブルへ格納する。長い同値区間を1塩基ごとのInterval配列に展開しない。物理RangeRecordの最大長65,536 bpで分割し、読み取り側は再び結合する。

RoundingはNearestAway・Floor・Ceil・TowardZero。実数書き込みには必須引数とし、NaN/Infと量子化後のInt32超過を拒否する。NearestAwayはちょうど半分の場合にゼロから遠い整数へ丸める。Raw APIへFloat64を暗黙変換しない。

### 12.1 失敗時とファイル公開

パス作成は同じディレクトリの一時ファイルで実行し、finish成功後にrenameする。既定で既存destinationの上書きを拒否する。`overwrite: true`をWriteOptionsで明示した場合のみ置換する。未完成ファイルを有効な出力として公開しない。OSごとの置換原子性の差はテストし、保証できないプラットフォームで一律に原子的と記載しない。

IO出力は取り消し可能とは限らない。非所有IOは閉じないが、失敗後のデータは無効とする。finalizerでfinishして完全性を保証しようとせず、finalizerは資源の解放だけを行う。非ブロックAPIの利用者は明示的にfinish/closeする。

正常ブロック終了でfinishに失敗したら、その例外を返しabortする。利用者ブロックの例外とcleanupの例外が両方起きた場合は、利用者の例外を優先し、cleanupの情報を失わない形で保持する。失敗したWriterは再利用せず、以後のwriteはWriterStateError。

索引生成をWriteOptionsの`indexes`で選べるようにする。SFI・sumを要求した場合は生成成功もfinish成功の条件に含める。

## 13. 並列読み取りと並列書き込み

既定はworkers=1。workers<=0はArgumentError。workers>1はライブラリ専用のParallel Execution Contextで実行し、アプリケーションの既定contextやグローバルなworker数を勝手に変更しない。対応しないビルド環境ではUnsupportedFeatureErrorとし、CPU並列処理を単なるspawnで代用したと説明しない。

並列経路で許す割り当ては実行器初期化、有限のworker数、結果の所有に必要なものに限定する。partitionごとに新規Fiber/Channel/Proc/Decoderを作らず、workerが小さなpartition descriptorを受けてworkspaceをresetする。joinのために全partitionのpartial resultを保存せず、必要な結合順と予算の範囲で逐次mergeする。

読み取りのpartitionはRegionに限定され、独立したDecoder/SecondaryCursor/Reducer状態を持つ。Sourceや有限キャッシュのみを共有する。巨大な同値区間がpartition境界をまたいでも統計の重みと値は変わらない。

入力・結果のキューとin-flight partition数に上限を設ける。worker例外で残りをキャンセルし、開始済みの処理をjoinしてから元の例外を返す。キャンセル判定はブロック境界に置く。利用者のブロック呼び出し中にSource/キャッシュのlockを保持しない。

Fileのcloseと実行中の読み取りの競合では、新規操作を拒否し、実行中操作をキャンセル・joinしてから所有Sourceを閉じる。公開Iteratorのnextは閉じたFileを検査する。mmapの解放とアクセスの競合を防ぐため、読み取り中のleaseを内部で管理する。

利用者ブロックを呼ぶ前に、Source/mmapを参照する読み取りleaseを解放する。scan_values/scan_rowsの借用Sliceは通常のデコードbufferであり、mappingの直参照ではない。利用者ブロック内のFile.closeが自分自身のleaseやworkerをjoinしてdeadlockしないようにする。close後、次のブロックの取得を試みた時点でClosedErrorとなる。

leaseはread operation/block境界のcountとensureによる管理を基本とし、各value/Intervalの取得で新しいReferenceオブジェクトを作らない。キャッシュのpinもframe/block単位にする。

### 13.1 書き込みpartition

```crystal
# regionsは事前検証済みの、重複しない予約領域。
writer.partitioned(regions, workers: 4) do |part|
  region = part.region
  part.write_values(region.start, values_for(region))
end
```

Writerの逐次モードとpartitionedモードは混在させない。partitionedは最初のwriteより前に呼び、予約領域の重複、染色体名、境界を一括検証する。各PartitionWriterは一染色体内のRegionを持ち、その内部だけで単調な書き込みを許す。全染色体を覆う必要はなく、予約外と各partition内の隙間はdefault_valueで埋める。

同じpacked byteへの競合を防ぐため、染色体終端を除くpartition境界を8 bp単位に揃える。利用者指定が揃っていない場合は拒否し、隠れた共有byte更新を行わない。内部分割器が領域を作る場合は自動的にこの条件を満たす。

二次テーブルはpartitionごとの一時ストリームへ書き、finishで座標順に組み込む。複数workerが同じコンテナdirectory allocatorを直接更新する設計にしない。primaryの互いに重ならないbyte範囲だけをpwriteまたは局所バッファ経由で書く。

全体の一時ディスク容量と各workerのバッファに予算を設ける。workerの失敗で全体をabortする。公開PartitionWriterはブロック終了後に無効になる。

## 14. Source、HTTP、mmap

内外の境界はゲノムカーソルではなく、絶対バイトoffsetによるSourceとする。

```crystal
abstract class D4::Source
  abstract def size : Int64
  abstract def read_at(offset : Int64, buffer : Bytes) : Int32
  abstract def close : Nil
  abstract def closed? : Bool
end
```

read_atは部分読み取りを許し、EOFで0。呼び出しによる共有の論理位置を持たない。read_exact_atはこれを繰り返し、途中のEOFをFormatErrorまたはUnexpectedEOFErrorにする。Source実装は並行呼び出しへの安全性を保証し、提供できなければ内部で直列化する。

| 実装 | 動作 |
|---|---|
| LocalSource | 利用可能ならpread、代替はseek+read全体を同期 |
| IOSource | seek+readを一つの同期操作にし、借りたIOの外部同時利用を禁止 |
| MemorySource | 不変Bytes。テスト入力はコピーまたは明示的所有移譲 |
| HTTPSource | byte Range、request-size制限、有限のblock cache |
| MappedSource | 任意のローカル最適化。内側でmappingの寿命を所有 |
| CountingSource / FaultSource | テスト用の読取回数・転送量計測、short read/障害注入 |

入力SourceはFileの寿命中に不変であることを要求する。外部のtruncate、追記、同じIOへの別操作はサポートしない。メモリSourceのBytesを利用者が変更できる借用モードは高度な明示的オプションとする。

### 14.1 HTTP

```crystal
require "d4/http"

source = D4::HTTPSource.new("https://example.org/data.d4")
D4.open(source, sync_close: true) do |file|
  puts file.mean("chr1", 1000, 2000)
end
```

URLとローカルパスは別入口。HTTPは任意requireとし、ローカル利用にHTTP/TLS設定を混ぜない。

- Rangeへの206応答とContent-Range、要求した範囲・全長、response lengthを検証する。
- 最初のRangeに200が返った場合、ファイル全体を自動ダウンロードしない。RangeNotSupportedErrorを返す。全体ダウンロードは別の明示的操作にする。
- transparentなcontent encodingを避け、Rangeのoffsetと受信byteが一致するようにする。
- 可能ならETag/Last-Modifiedで実行中の変更を検出し、異なる版を混ぜない。
- 接続、読み取りtimeout、retry回数、redirect上限、並行request数を設定可能にする。
- seekのたびに一塩基相当のrequestを出さず、隣接byteを合併してblock cacheに格納する。
- 同じblockの同時fetchを統合し、応答待ちの間はキャッシュlockを保持しない。

二次フレームのランダムアクセスはSFIがある場合に効率化する。SFIなしなら必要なstreamを走査する可能性があることを説明し、全ケースを一定時間のランダムアクセスと宣伝しない。

### 14.2 mmap

mmapは性能測定後に追加する。まずportableなread_at経路を完成させ、すべての意味をそこで検証する。mappingを直接Sliceとして利用者へ渡すAPIは初版に置かない。mappingの寿命を跨ぐunsafe pointerを公開せず、byte末尾の読み越しを禁止する。

## 15. 索引の公開APIと構築

```crystal
D4.build_indexes(
  "depth.d4",
  track: "",
  kinds: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum],
)

D4.open("depth.d4") do |file|
  puts file.default_track.has_index?(D4::IndexKind::Sum)
  puts file.sum("chr1", 1000, 2000, index: D4::IndexPolicy::Scan)
end
```

IndexKindはSecondaryFramesとSum。IndexPolicyはAuto・Scan・Require。FileからTrackの索引情報へ委譲し、曖昧な`has_index?`だけで種類を隠さない。

| Policy | 動作 |
|---|---|
| Auto | 対応する索引がなければ走査。精度条件を満たさない索引も走査へ戻る |
| Scan | データから計算。sum indexによる集計を使わない。SFIによるbyteアクセス最適化は許す |
| Require | 必要な索引がなければMissingIndexError。精度を保証できなければIndexPrecisionError |

索引が存在するのに破損している場合は、AutoでもCorruptIndexErrorとする。不存在・非対応・破損をすべてfalseへ丸めない。完全に索引を使わず検証する内部経路を別に持つ。

SumIndexの構築granularityは初版では65,536 bpに固定する。読み取りはヘッダのgranularityを読む。短い領域、索引境界を一つまたぐが完全なブロックを含まない領域、末尾の短いブロックを特別に検証する。完全なindexed blockがない場合は領域全体を一度だけ走査する。左・右の端点補完が重複する実装を避ける。

SFIはフレームoffsetだけでなくrecord offset、first-frame状態、染色体/領域の対応を保持する。定数名ではなく実際のserialized object名を使い、`s_frame_index`と`secondary_frame_index`のようなRust内の名前の差をfixtureで確認する。

build_indexesはローカルパスだけを受け付け、既定ではコピーを作って索引を構築し、成功後に置換する。巨大ファイルのコピー時間・ディスク使用量を明示する。任意の`in_place: true`は排他的アクセスを要求し、失敗時の原子的復旧を保証しない。既存Readerと同時に変更しない。

複数トラックでも明示したトラックrootの.indexへ構築する。添付Rustの「構築は単一トラック前提」という制約をCrystalの公開APIの制約にはしない。ただし生成物がRustの指定トラックReaderから読めることを相互運用テストで確認する。

## 16. トラック結合、コピー、診断、外部入力

### 16.1 結合

```crystal
D4.merge("cohort.d4", {
  "normal" => D4::TrackInput.new("normal.d4", track: ""),
  "tumor"  => D4::TrackInput.new("tumor.d4", track: ""),
})
```

mergeはファイルのbyte連結ではなく、選択したトラックdirectoryを新しいコンテナへコピーする。多トラック入力に対して「最初のトラック」を推測しない。全トラックをコピーする場合は別の明示的な入力指定を使う。

染色体集合・順序が異なるトラックの格納自体は許すが、Matrix作成時には一致を要求する。コピーでデータが変わらなければsum indexは保持可能。SFIに保存されるoffsetの基準を確認し、directory内の位置変更で無効になる索引は移植時に再構築する。索引をそのままコピーできると未検証のまま仮定しない。

数GBのトラックを全件decodeしてencodeし直すことを既定にしない。固定サイズのbyte bufferでcopy/relocateする経路を作る。元のファイルと同じパス、同じFileをdestinationに指定した場合は拒否する。作成・上書き・abortはWriterと同じ方針。

### 16.2 検証・診断

`D4.validate(path_or_source, *, deep = false)`はValidationReportを返す。通常はヘッダ、entry/frameの境界、メタデータを検証する。deepは全テーブルを走査し、座標順・secondary record・圧縮block・索引と実データの一致を確認する。巨大なファイルのdeep validationをopenの既定動作にしない。

任意の`d4/inspect`でdirectory・blob・frame・索引の位置をIOへ書き出せるようにする。通常の公開APIへFramefileの書き換え操作を混ぜない。

### 16.3 外部入力

bedGraphは`require "d4/bedgraph"`で、IOからRegion/valueを一件ずつ読み、Writerへ流す。コメント、不正行、並び順、重複、実数量子化を明示する。スキップを既定にせず、不正行は行番号付きで例外にする。書き出しはTrackのeach_intervalからIOへストリーミングする。

BAM/CRAM/SAM側はChromosome列とInterval(Int32)列を提供するアダプタとする。read filter、mapping quality、重複、overlap、参照配列の条件をそのアダプタ側で確定し、D4 codecへ持ち込まない。BigWigはFloat64区間と量子化方針を渡す。中核はhtslibをリンクしない。

外部アダプタがCライブラリを使う場合、その拡張についてまで純Crystalであると称さない。BAMの辞書推定はこのInterval列に汎用Samplerを適用することで可能になる。変換CLI・描画・サーバーは中核の完成条件に含めない。

## 17. 内部構造

依存方向を上から下への一方向にし、public型同士の循環を避ける。

| 層 | 主なモジュール | 依存先 |
|---|---|---|
| 公開API | File・Track・Matrix・Writer | 検証済み領域、走査、作成サービス |
| 問い合わせ/集計 | QueryPlan・BlockScanner・ReducerRunner | metadata・table reader・index |
| テーブル/索引 | Primary/Secondary・DictionaryCodec・SFI・SumIndex | コンテナとbyte codec |
| 形式 | Container・Directory・Blob・FrameStream・EndianCodec | Source/Sink |
| I/O | Local/Memory/IO/HTTP/Mapping | Crystal標準IO・HTTP・OS |

配置案:

```text
src/d4.cr
src/d4/types.cr
src/d4/errors.cr
src/d4/options.cr
src/d4/file.cr
src/d4/track.cr
src/d4/scaled_track.cr
src/d4/matrix.cr
src/d4/writer.cr
src/d4/dictionary.cr
src/d4/source.cr
src/d4/format/{container,directory,blob,frame_stream,endian}.cr
src/d4/codec/{primary,secondary,range_record,compression}.cr
src/d4/query/{region,scanner,iterators,planner}.cr
src/d4/stats/{reducer,reducers,histogram,coverage}.cr
src/d4/index/{sfi,sum,builder}.cr
src/d4/execution/{serial,parallel,partition}.cr
src/d4/merge.cr
src/d4/validation.cr
src/d4/http.cr
src/d4/bedgraph.cr
```

これは責務の分割案であり、一型ごとに必ず別ファイルを作る指示ではない。小さい関連型はまとめ、機能を実装する前に空のファイルを大量に用意しない。

### 17.1 形式互換の必須事項

- `d4\xDD\xDD`のmagicと8byteのprefix、root offsetを確認する。
- バイト列の構造を明示的にlittle endianで読み書きする。Crystal/Rustのstruct memory imageをそのまま保存しない。
- serialized JSONのenum/tag、headerの既定denominator、二次テーブルのmetadataをfixtureで固定する。
- 一次テーブルのbit order、染色体ごとのceil(size*K/8)、padding、最大コードのfallback、K=0を検証する。
- RangeRecordは10byteのpacked形式、left+1、length-1の16bit表現を明示的に実装する。
- DEFLATEはraw DEFLATEとして扱い、zlib/gzip wrapperと混同しない。先頭フレームのcompressed/raw fallbackを実装する。
- SFIのpacked fields、sum index headerのenum表現・padding・Float64を、対象Rustのbyte fixtureから確認する。ホストABIのsizeofに依存させない。
- 不明なrecord formatやcompressionはUnsupportedFeatureError。未知のJSON補助フィールドは基本的に許し、既知フィールドの不正値は拒否する。

### 17.2 走査の実装

公開each_intervalの最大同値区間化と、内部の高速BlockScannerを分ける。統計処理のために常に全データをRLE化する必要はない。K=0や長いsecondary区間は区間単位で処理し、値が頻繁に変わるprimaryはpacked blockを直接decodeして集計する。

read_values_into、each_value、each_interval、Reducerは、同じprimary/secondary統合ロジックを使う。正しさのための統合規則を四つの経路で別実装しない。最適化されたdecoderと低速参照decoderは、独立したアルゴリズムとしてテストで比較する。

Scannerは統合済みの数値を利用者bufferまたはReducerへ直接送る。Primary Array→Secondary Array→統合Array→Interval Arrayという中間列を作らない。secondary recordはbyte bufferから数値フィールドを直接取り出し、再利用するparser classのcursor/fieldへ読み込む。各recordに独自structを作る設計を必須にしない。公開each_intervalの保持可能なInterval classには区間数に比例する割り当てがあり得るが、内部集計はInterval instanceを作らずstart/stop/valueを直接受け取る。

## 18. 性能・資源の契約

性能の目標値は同じハードウェアでRust版と比較して設定する。「Crystalなので同等速度」と推定だけで保証しない。APIは次の構造的な劣化を防ぐ。

| 処理 | 目標となる挙動 | 避けるもの |
|---|---|---|
| each_value / read_values_into | 有限blockでdecode、O(block)の作業領域 | 一塩基ごとのseek・syscall・Hash lookup |
| each_interval | 物理境界を隠した区間列、定数的な持ち越し状態 | 全区間の事前Array化 |
| sum/mean | index blocksと非重複な端点走査、またはストリーミング | 領域長サイズのInt32配列 |
| Histogram/Coverage | 区間長の重み付け・有限のcount配列 | 全塩基の一時配列とsort |
| Matrix | block単位の列decode、再利用row buffer | 集計時の一塩基ごとのRow allocation |
| Writer | packed byteをまとめて書く、secondaryを区間でencode | dense valuesをInterval配列に変換 |
| HTTP | 隣接Rangeの合併・有限cache | 無制限fetch、全ファイル先読み |
| Merge | O(input bytes)のcopyとoffset relocation | 全入力の再decode・全体をメモリに保持 |

ReadOptionsにはcache_bytes、max_materialized_bytes、max_metadata_bytes、max_decoded_frame_bytes、max_index_bytes、aggregate_state_bytes、max_active_states、worker_buffer_bytes、max_concurrent_requestsを置く。初期案は共有cache 32 MiB、明示的materialization上限64 MiB。その他の上限は最大サイズfixtureと測定で固定し、任意の巨大な長さを信用してallocateしない。aggregate_state_bytesは全workerを合わせた予算、worker_buffer_bytesはworkerごとの予算である。

writerにはblock_size、compression、indexes、overwrite、worker_buffer_bytes、temp_bytes_limitを持つWriteOptionsを用いる。圧縮設定は`Compression.none`または`Compression.deflate(level: 0..9)`。物理frameサイズなどは初版では内部設定に留め、公開する場合も正当性を保つ検証を伴わせる。

キャッシュ予算はFile/Source共有分、worker buffer予算はworkerごとであり、総量は概ね共有予算 + workers*buffer予算 + 集計状態 + 返す結果。ReadOptionsでcacheだけを制限してプロセス全体のRSS上限を保証したと説明しない。保持されたeach_blockの出力や利用者のArrayは別である。

この式は生存する作業データの設計予算であり、未回収のgarbage、GC heapの予約容量、native圧縮/TLS状態、Fiber stack、mmap/page cacheを含むRSSの厳密な上限ではない。cache予算には所有するbyte領域をcapacityで数え、viewのlengthだけで計算しない。pinされたcache blockと作業中blockも計上し、evict後も参照が残ったBytesを「解放済み」と数えない。

ローカルのランダム読み取りはsecondary frame indexとキャッシュ状態に依存する。無索引・圧縮secondaryへのランダムアクセスには線形走査が必要な場合がある。データ特性による複雑さをドキュメントで隠さない。

### 18.1 ベンチマーク

release buildで、RustとCrystalを同じデータ・同じ出力・同じworkersで比較する。初回/暖キャッシュを分け、wall time、CPU time、peak RSS、allocation、Sourceのread数/byte数、HTTP request数を記録する。

最低限、K=0・1・6・8・16、secondary少量/多数、無圧縮/DEFLATE、100 bp/100 kb/染色体全体、単一/複数トラック、連続/ランダム領域、一定値/頻繁な値変化を測る。

暫定の調査基準は、primary連続decodeがRustの2倍超、無索引の集計が3倍超、入力長を伸ばしたときに走査の作業RSSが線形増加、HTTP request数が塩基数へ比例する場合。倍率はリリース保証ではなく、要因分析と実装見直しの入口とする。小さい領域での固定オーバーヘッドと大領域のthroughputを混同しない。

### 18.2 メモリ効率レビューの結論

このレビューはPLANと添付Rustコード、Crystal公式の型・GC・Slice・closureの文書に基づく静的な調査である。Crystal版はまだ実装されておらず、割り当て回数・GC時間を実測した結果ではない。設計上必ず発生する出力の所有コストと、実装次第で回避できるコストを区別する。

旧PLANは「作業メモリが有限」「配列を全件作らない」を重視していたが、それだけではGC言語に十分ではなかった。小さなblockを何百万回もnewしてすぐ捨てれば、生存データの量は有限でも累積割り当てとGC負荷が大きくなる。保持量・割り当て総量・コピー量を別の指標として扱う。

| 優先度 | 問題候補 | 局所最適化で済むか | 改訂での扱い |
|---|---|---|---|
| P0 | 保持可能なInterval/RegionResult/Summaryに結果ごとのheap objectが必要 | 原則classを維持し、内部走査と所有結果を分ける | 内部はscalar/bufferで処理。structは実測で明確な効果があった型だけ |
| P0 | Matrix.each_rowの保存可能なArrayが一行ごとに必要 | 所有契約を保ったまま除去不可 | 便利APIとして明示し、scan_rows/read_rows_intoを性能用にする |
| P0 | each_blockの保持可能な出力bufferを毎block新規確保 | 所有契約を保ったまま再利用不可 | scan_valuesと使い分け、wrapperの型変更だけで解決したとしない |
| P0 | Histogramを領域×partitionごとに作り全状態を同時保持 | stateの構造とスケジューラに対策が必要 | reset/in-place merge、進行中stateだけにpool slot、byte予算 |
| P0 | Matrix.aggregateが各領域に列Arrayを返す | 返す構造を変えずに除去不可 | aggregate_intoを追加し、row-major outputへ格納 |
| P0 | 頻回のHistogram/Coverage結果が独立bufferを要求 | 結果を所有させる限り必要 | histogram_into/coverage_intoを追加 |
| P1 | Matrix block_sizeが列数と独立でworker数倍に増える | 内部計画で可能 | byte予算から行数を算出、重複bufferをなくす |
| P1 | CPU pool/Fiber/Channel/closureをpartitionやバッチごとにnew | 実行器構造の変更が必要 | 有限のFile所有pool・descriptor・workspaceを再利用 |
| P1 | 順次走査がcacheを入れ替え続けBytesを作って捨てる | cacheの入場方針とbuffer所有で可能 | 逐次scratch経路とrandom cache経路を分ける |
| P1 | 圧縮blockごとにReader/Writerとengine内部状態を再生成 | Codec境界で対策が必要、標準wrapperのみで可能とは限らない | engine再利用を検証。native割り当ても計測 |
| P1 | SFI/indexのbyte列・変換Array・全track cacheが二重保持 | index表現・構築方式で可能 | 予算内の一つの表現、paged読取/stream構築 |
| P1 | normalize_regionから公開metadataコピーを呼ぶ | 内部経路の変更だけで可能 | name→idを一度解決、内部不変参照を使う |
| P2 | 区間/フレーム/thresholdごとの文字列化・Proc化 | ほぼ局所的に可能 | 成功hot pathの文字列とescaping closureを除く |

P0はAPIと基本型の実装前に契約を固める項目、P1は大量データの機能を完成と呼ぶ前に確認する項目である。便利APIからすべての割り当てを取り除くことは目標にしない。最短の性能用経路が所有コストを強制されないことを目標にする。

### 18.3 GC向けのデータ表現

- Raw/Scaledの大きな作業bufferはBytes、Slice(Int32)、Slice(Int64)、Slice(Float64)などpointer-freeな要素を基本にする。標準の型情報に基づく割り当てを使い、GCが内部pointerを走査しなくてよい領域を活用する。
- String/File/Trackなどの参照を含むRegionResultを、手動でmalloc_atomicへ入れない。参照が回収されてしまうため、primitive bufferの最適化を任意型へ拡張しない。
- hot loopにArray(Reference)、JSON::Any、Box、巨大な混合Unionを持ち込まない。抽象Sourceへのblock単位のdispatchは許すが、Reducerと値の具体型は保持する。
- Chromosome名は一度作ったStringを共有し、内部partition・active region・SFI検索は数値chrom_idを使う。各塩基/区間でname.to_s、文字列連結、tupleキーの文字列化をしない。
- File/Trackを開くときの配列・Hash・Iterator一個の割り当ては許容する。hot pathの最適化のために、すべてをunsafe pointerや手動allocatorへ移す必要はない。
- stdlibの普通のblockをyieldする形を基本にし、blockをescaping Procとして保存する場合は生成頻度を走査開始またはworker開始に限定する。すべてのblock/Procが必ずheapを確保すると決めつけず、捕捉とescapeのある経路を測る。
- 参照を含むpool/queueの使用済みslotは明示的にnil/既定値へ戻す。論理的なlengthを縮めただけでcapacity領域が古いFile/Bytes/Procをrootし続けないことを確認する。

### 18.4 再利用するworkspaceと再入可能性

内部ScanWorkspaceはprimary byte scratch、decoded value scratch、secondary frame/record scratch、small cursor、集計state slotを保持する。workspaceは同時に一つの走査だけが借り、workerと同じ有限個数を作る。利用者callback内から別のqueryを呼んだ場合、外側のscratchを再利用しない。新しいslotを予算内で借りるか、収まらなければResourceLimitErrorにする。

ScanWorkspaceのresetは位置・valid length・stateを更新し、同じcapacityのbufferを使う。各blockでclear→新規Slice(size)という手順にしない。大きさの変化はcapacityを超える時だけgrowthし、最大capacityに制限する。たまたま読んだ巨大frameで全workerのpoolが巨大化したまま残らないよう、過大なbufferは返却時にpoolへ保持せず、通常サイズの再利用slotと分離する。

read_values_intoの出力と内部scratch、Histogram countsとstate pool、Matrix出力とcolumn scratchをaliasさせない。GCは物理的なメモリ寿命を保っても、「次の反復で上書きされた値」の意味上の安全性までは保証しない。

逐次モードはworkspaceを一つ使い、並列モードはworkers個を使う。partition descriptorはchrom_id/start/stop/output slotを持つ再利用可能なclass、または既存の数値bufferのslot indexで渡す。同時使用中のdescriptorを上書きしない。descriptorをstructにすることを前提にしない。reset後にもString/Bytesなどの古い参照が残らないことを確認する。

### 18.5 生存量が小さくても累積割り当てが大きい経路

**所有結果**: each_rowで100万行を返す場合、利用者が保存できる独立したArrayという契約のため、100万個の配列とその内容の格納領域が必要になる。各行が2列なら値payloadだけで約8 MBだが、Row class・GC object・capacity・alignmentのコストは別にある。wrapperの型を変えるだけではArrayのコストは消えない。scan_rowsなら一つの行blockを再利用できる。

**所有block**: each_blockを消費してすぐ捨てる利用でも、保持可能な出力を作る契約ではdecodeされた出力量に比例する割り当てが発生する。scan_valuesでcaller bufferを借りる経路に変更できることが、構造的な対策となる。each_blockでcacheの小さなviewを返して出力コピーを隠すと、viewが巨大cache領域をpinし、別の問題を作る。

**範囲辞書**: K=31は形式上の上限でも、2^31個のInt32を展開すれば値だけで8 GiBになる。範囲辞書はlow/highからコードを計算するため、このメモリを使う必要はない。値リスト辞書の巨大サイズは実際の入力/出力予算に基づいて拒否する。

**Matrix**: 65,536行×64列×4byteは一出力bufferで16 MiB、8workerなら128 MiBになる。全列分の別bufferやScaledのRaw+Float64変換bufferを追加すればさらに増える。公開の行数を固定する前に、列数に応じた行数計画と直接変換を実装する。

**集計state**: 256領域×8partition×4,096bin×8byteはcount payloadだけで64 MiBになる。これを毎バッチ新規確保すれば、例えば100バッチで6.25 GiBの累積count allocationになる。全partitionの結果を保持せず、進行中stateと決定的mergeの有限bufferだけを使う。reset/zero clearはCPUのメモリ書き込みを要するが、新規heap objectを作る必要はない。最初から複雑な世代番号付きhistogramを採用せず、clearの実測後に検討する。

### 18.6 Cache、索引、圧縮の注意点

**Cacheのadmission**: 大きな順次scanは、cacheへすべて入れて即evictする経路にしない。再利用scratchを使うstreaming経路を選び、random query用cacheの容量を汚さない。キャッシュmiss時のnew(Bytes)がblock数に比例する場合、bounded RSSだけを根拠に効率的と判断しない。固定slotのbufferを使い回せる場合は使い、pin中のslotを上書きしない。

**Pinと参照**: 借用viewは短いblock処理中だけ保持する。保存可能なValueBlockは独立したpayloadを持ち、cacheを長期間pinしない。cache容量はすべてのtrack/Sourceの使用量を含むscopeで定義し、Matrixの各Trackにcache_bytes全量を別々に与えない。複数FileからのMatrixでは、Fileごとの予算が合計されることを説明する。

**SFI/SumIndex**: 小さいindexは一度読み共有する。大きいindexはmax_index_bytes以内でpage単位に読む。packed SFIのraw Bytesとdecoded entries Arrayを恒久的に二重保持しない。数値fieldごとのbufferまたはbyte pagesから境界付きdecodeを選び、検索に必要な値だけを読み取る。SFIはon-disk entryが30byteなので、100万件ならpayloadだけで約30 MB。全entryのclass instanceを常駐させることは必須ではなく、参照先を示すscalar offsetや再利用するcursor classで処理できる。独自entry structは実測条件を満たすまで採用しない。

build_indexesは全ゲノムの各binをTaskOutput objectとして集めない。SumIndexのentry数は染色体長から先に分かるため、固定blobを予約して有限bufferで順に書く。SFIのentry数が事前に不明なら、有限の一時スプールまたは二回のstream走査を使い、全entryの配列作成を必須にしない。

**DEFLATE**: 圧縮済みBytes→IO::Memoryコピー→Readerの新規buffer→展開Bytes→RangeRecord Arrayという多段コピーを避ける。byte viewを入力にし、worker scratchへ展開し、recordはその場でdecodeする。raw/decoded payloadを同時cacheする場合は両方を予算へ数える。

添付Rustのsecondary writerはcompression.rsでbufferとunused_bufferを交換し、compressor.resetを使って再利用している。Crystal側で毎frame新しいWriter/Readerを作るだけでは同等の割り当て特性を得られるとは限らない。

Crystal 1.21のCompress::Deflate::Reader/Writerの公開インターフェースから、任意の独立したD4圧縮streamに対するengine state再利用を当然視しない。readerのrewindは同じ入力への巻き戻しであり、別のcompressed blockへresetできる証明ではない。標準wrapperでの正しい基準経路を先に作り、engine初期化とnative allocationを計測する。

必要なら交換可能な内部Codecへ、公開zlib APIのinflateReset/deflateResetを使う小さなCrystalアダプタを用意する。zlibのresetは同じengine stateの再利用に使えるが、各D4 blockが独立したraw DEFLATEであることを毎回守る。これはD4のC/Rust実装に依存することではない。標準ライブラリのprivateメソッドに依存したpatchは採用しない。reset可能なengineが未実装なら、その圧縮経路についてblock数に比例するnative/GC割り当てが残る制約を記録する。

**HTTP**: HTTP request/response/TLSにはlibraryの外側を含む割り当てがある。一requestを完全な無割り当てにすることより、Rangeを適切にまとめてrequest数を抑える。response bodyをStringとして全読みし、そのto_sliceをcacheへコピーする経路を作らない。

### 18.7 計測と回帰テスト

GC.statsのheap_size/free_bytesは保持・heap容量を見る指標であり、累積割り当ての代用にしない。GC.stats.total_bytesの差分、bytes_since_gc、GC.prof_statsで対象版が提供するGC回数・時間を確認し、RSSと合わせて測る。total_bytesはGC heapへの割り当てであり、zlib/TLS/native malloc、mmap/page cacheを直接数えるものではない。native allocatorの計測とOSのRSSを別に取る。

計測はrelease buildの独立プロセスで行い、入力・出力buffer・Reducer設定・cache/workspaceを事前に準備しwarm-upする。測定区間にログの文字列化、puts、入力Array生成、利用者によるto_aを混ぜない。必要ならGC.collectは測定前だけに使い、ライブラリ内部でblockごとのGC.collectやGC.disableを性能対策として行わない。

```crystal
# 将来のallocation regression specの測定骨格。
# file/bufferは準備済み。warm-upと測定区間を分ける。
file.read_values_into("chr1", 1000, buffer)
before = GC.stats.total_bytes
1000.times do
  file.read_values_into("chr1", 1000, buffer)
end
allocated = GC.stats.total_bytes - before
```

GC.statsはプロセス全体の値であり、同時に動く別fiberの割り当ても含む。まず単worker・MemorySourceのspecで検証し、並列/native/HTTPは別jobで測る。計測骨格だけではworkspaceやcodecが無割り当てだと証明したことにはならない。

| 測定ケース | 期待する割り当ての傾向 |
|---|---|
| warm cacheのpoint value/一塩基meanを多数反復 | Iterator/Region class/lease object数がcall数に比例しない |
| 同じworkspaceで長さを10倍にしたuncompressed scan_values | 累積scratch allocationがblock数に比例しない |
| each_intervalの同値区間数を大きく増やす | 公開Interval classの所有コストを測る。内部scan/集計はInterval instanceを作らない |
| histogram_into/coverage_intoを同じbufferで反復 | count配列の再確保なし。clearのCPU時間を別計測 |
| Matrix.aggregate_intoで領域数を増やす | 領域ごとの列Arrayを作らない。出力bufferは準備済み |
| each_row/each_block/owned Histogramを保持する | 所有する出力に比例する割り当てを許し、性能用経路と区別 |
| 既定cacheを超える長いsequential scan | cache miss/evictionによるnew(Bytes)の連続発生を検出 |
| 圧縮frame数を増やす | payload bufferとengine stateの再利用を別々に確認 |
| workers/列数/bin数/active領域を増やす | 設計したbyte予算で制限。state数の積による意図しない増加を検出 |

厳密な「すべて0byte」はコンパイラや標準ランタイムの版に依存し得るため、portableなspecでは許容する固定初期コストと入力サイズに対する増加傾向を定義する。数値bufferの再確保は内部AllocationCountersでも直接数え、総heap bytesの差分だけで説明しない。GC objectの種類別回数は明示的instrumentationで取り、GC.stats.total_bytesからobject数を逆算しない。

### 18.8 今回変更したAPIと、変更せずに直す項目

APIへの追加はhistogram_into、coverage_into、Matrix.aggregate_intoに限定する。結果を保持する便利APIは残す。使用例と性能ドキュメントの推奨経路はscan/intoを先に示す。既存each_rowの戻り値を借用viewへ黙って変更しない。

直接decode、name→idの解決、workspace/worker再利用、cache admission、byte-budgetによる内部block計画、索引のstream構築は通常の利用APIを増やさずに実施する。struct化は事前の一律方針から外し、3.1の実測条件を満たした個別の最適化だけにする。再利用用の公開Workspaceや任意のobject poolを最初から利用者へ要求しない。

不変な数値型、値リスト辞書、圧縮backend、可変結果を持つReducerについてはcompile/allocation specで確かめ、実装後に必要な追加APIだけを再検討する。所有権による下限を最適化不足と取り違えず、割り当てを減らすために寿命・並行アクセス・結果の保持可能性を壊さない。

### 18.9 structを採用する場合の必須記録

1. 同じAPI・所有権のclass基準実装と、対象型だけを変えたstruct候補を用意する。buffer再利用など別の変更による改善をstructの効果に含めない。
2. 実利用に近い小/大データ、格納・返却・capture・並列の主要経路で複数回測り、compiler版・release設定・ハードウェア・データを記録する。
3. wall time/throughput/latencyとallocation/GC/RSSを比較する。allocation減少のみ、microbenchmark一つのみ、理論上のstack配置のみを採用根拠にしない。
4. 再現可能で明確な処理性能の改善があり、主要な別経路に大きな回帰がない場合だけ対象型に限定して採用する。差が不明確ならclassを維持する。
5. 型の変更が公開APIのcopy/alias/identityへ影響する場合は、性能だけでなく互換性と所有権も再検証する。記録と回帰テストを残す。

この比較は将来の実装工程で行う。現在のPLANには、測定済みで採用を許可した独自struct型はない。

## 19. エラー体系

| エラー | 発生例 |
|---|---|
| ArgumentError | 負の座標、逆転、空バッファ、重複辞書、workers<=0 |
| UnknownChromosomeError / UnknownTrackError | 指定名がない |
| TrackSelectionError | 複数トラックで既定が未選択 |
| RegionBoundsError | 染色体長を超える領域 |
| ClosedError / WriterStateError | close後のアクセス、失敗したWriterの再利用 |
| FormatError / UnexpectedEOFError | 無効magic、truncated frame、invalid metadata |
| UnsupportedFeatureError | 未対応record/compression、対応外座標、利用不可の並列機能 |
| MissingIndexError / CorruptIndexError / IndexPrecisionError | 索引不存在、破損、正確な和を保証不可 |
| AllocationLimitError / ResourceLimitError | 結果・frame・histogram・一時容量の予算超過 |
| NotSeekableError / RangeNotSupportedError | 非seek入力、HTTP Range未対応 |
| HTTPError / SourceChangedError | 不正HTTP応答、実行中の入力変更 |
| IncompleteHistogramError | 範囲外countのあるHistogramから完全な分位点を要求 |

D4固有のエラーは`D4::Error < Exception`へまとめる。ArgumentErrorはCrystalの標準例外を使う。OSのIOエラーを不用意に空配列やfalseへ変えず、元の例外を保持する。エラーにはpath/track/chromosome/offsetなど、原因の判断に必要な文脈を含める。

グローバルなerror_number/clear_errorsを持たない。`?`は不存在の場合にnilを返す意味であり、破損・ネットワーク障害までnilに変える意味ではない。

## 20. テスト方針と受け入れ条件

### 20.1 独立した低速参照実装

小さなArray(Int32)を染色体ごとに持つ参照モデルをspec専用に作る。point、領域値、最大同値区間、sum、mean、Histogram、Coverageを素朴に計算し、実装のpacked decoderや索引を流用しない。Writerへの入力から期待値を生成する。

### 20.2 単体・性質テスト

- K=0..16のbit codec、byte境界、最後のpartial byte、最大コードfallback、負値。大きいKは小さな人工byte fixtureで確認する。
- range/map辞書の同じ最終値、K=0の二次値優先、任意の辞書順序。
- RangeRecord長1/65,536/65,537、left+1、染色体末尾、cross-frame record。
- 無圧縮/DEFLATE、先頭フレームのraw fallback、empty secondary stream。
- 長いIntervalと短い複数Intervalの同じ論理データ。
- each_intervalを展開した値列がvaluesと一致し、隣接同値区間が残らない。
- 領域分割したsumの和が元領域のsumと一致する。
- Histogram counts + below + above、Coverageの母数が領域長と一致する。
- 空領域、長さ0の染色体、終端point、未知名、inclusive Range終端。
- Int32の極値、Int64のsum、UInt32末尾付近のoffset/size計算。
- denominatorが1以外の正負値、量子化の丸めとoverflow。

ランダム性テストは固定seedを記録し、失敗する最小入力を保存する。round tripだけではReaderとWriterが同じバグを共有できるため、参照モデルと固定byte fixtureを必ず併用する。

### 20.3 相互運用

Rust生成→Crystal読取、Crystal生成→Rust読取を両方行う。チェック対象はlogical values、chromosome順、dictionary/code順、denominator、トラック名、圧縮、SFI、sum index。複数トラックmergeと索引付きcopyも確認する。

Rustは開発/CIのoracleとしてのみ使い、配布物の実行時依存にしない。対象は添付snapshotとして固定し、後からmasterの状態を互換基準へ混ぜない。すべての有効ファイルでbyte-for-byte同一を要求せず、基本構造の固定fixture以外は意味の一致を評価する。

Rustの統計結果だけを正解にしない。添付Histogramのbelow側の区間重みやPercentCovの負値→unsigned変換など、望ましい意味と異なる処理があり得る。差が出たら独立モデル・形式・定義で判断し、意図した相違を記録する。

### 20.4 索引・境界テスト

65,536の直前/直後、同じブロック内、境界一つをまたぐが完全ブロックなし、完全ブロックあり、最後の短いブロック、空領域を含める。Auto/Scan/Requireで整数和を比較する。

巨大granularityの人工indexでFloat64精度条件外を再現し、AutoのfallbackとRequireの例外を確認する。破損したindexのfinite/integer/sizeチェック、SFIのoffset・record offset・first-frame状態を検証する。deep validationで改変済みのsum indexを検出する。

### 20.5 寿命・並行・障害

- 二つのIteratorを交互にnextし、ループ内から別のvalue/meanを呼ぶ。
- Iteratorを作った後のFile.close、IOのsync_close=false/true、ブロック例外。
- Sourceのshort read・途中EOF・seek失敗、圧縮破損、frame参照cycle、範囲外offset。
- worker例外・キャンセル・途中close・重複partition・borrowed Sliceの上書き。
- Writerのwrite/flush/index生成/rename失敗を注入し、destinationが未完成出力へ置換されないことを確認。
- 逐次/並列で結果順と正確な値を比較し、同じByte範囲へ書き込まないことをCountingSinkで確認。

HTTPはローカルのテストサーバーを使う。206、200、416、Content-Range不一致、truncated response、ETag変更、timeout、retry、redirect、content encodingを再現する。外部ネットワークの可用性を通常specの前提にしない。

### 20.6 性能構造を検証するテスト

時間だけに依存するflakyなspecを避け、CountingSourceでランダム読み取り回数・request byte量・キャッシュ上限を測る。走査で呼び出し数が塩基数に比例しないこと、集計でvaluesを全件確保しないことを確認する。計時/RSSは別のbenchmark jobにする。

通常specにD4実行時ライブラリ・htslibを要求しない。Rust oracle jobは別に実行し、未実行なら明示的なskipまたはjob未実行として報告する。「ライブラリがないので何もせず成功」というtestを作らない。

## 21. 実装段階と完了判定

| 段階 | 成果物 | 完了条件 |
|---|---|---|
| A: 読み取り | Source、Container、Metadata、辞書、raw/圧縮table、File/Track、独立Iterator | Rustの単一/複数トラックfixtureを正しく読め、メモリ入力で通常specが通る |
| B: 書き込み | 逐次Writer、default fill、量子化、完了/abort | Crystal→Rustの読取成功、破損・部分公開を防ぎ、K=0/map/負値/圧縮を含む |
| C: 統計 | Reducer、summary/histogram/coverage、batch、Matrix、Sampler | 参照モデル一致、重み付き集計、区間とblock経路の一致 |
| D: 高速アクセス | SFI/SumIndex、HTTPSource、Merge、validation | Auto/Scan/Requireの一致、HTTP部分読み取り、merge後の索引正当性 |
| E: 並列/最適化 | execution context、partitioned Writer、任意mmap、benchmark | 直列/並列一致、寿命/障害テスト、性能劣化の原因を説明できる |
| F: 任意の入力/CLI | bedGraph、外部アダプタ、inspect/変換CLI | 中核への不要な依存がなく、外部フォーマットごとの意味を明記 |

各段階で通常spec・API使用例のcompile spec・必要なRust相互運用を実行する。最適化によって形式契約を変更しない。並列化・mmapを実装する前に、同じSource/codecの直列実装を正しく動かす。

ベンチマーク未実施なら性能目標の達成を主張しない。A/Bのみなら「読み書き可能」、A〜Eなら「主要ライブラリ機能を網羅」と表現を分ける。

## 22. 公開前に固定する項目

以下は利用者へ質問して停止するためのリストではなく、実装で確認・固定すべき残りの設計作業である。

1. 対象Rust snapshotでのFramefile/SFI/SumIndexの正確なbyte layout。特にenumの表現とpacked fields。
2. 読み取り資源上限の既定値と、妥当な巨大frameへの対応。対応範囲をfixtureで示す。
3. Crystal 1.21でのSource同期・Execution Contextの終了処理・Windowsのファイル置換/mmap。
4. Dictionary.valuesの汎用Enumerable入力と不正な既存辞書の診断方針。コード順を勝手に変えない。
5. generic ReducerとInterval(T)の実際のcompile spec。型推論の負担が大きい入口は名前付きの補助入口で改善する。
6. merge時のoffset relocationとSFIの再構築条件。raw directory copyで済む箇所を実データで確認する。
7. optional外部アダプタの範囲。純Crystal中核とnative依存を持つ拡張を明確に区別する。

## 23. 参照した実装と文書

### 添付snapshot

| 入力 | 版・同定 |
|---|---|
| d4-format-master(1).zip | `d4/Cargo.toml`のcrate versionは0.3.11。Git commitはarchiveから未同定 |
| SHA-256 | `49f79102a090ec9e105ac726b8766b99f7de1538db9ef0a76f1aad5bd48a7aa8` |
| d4.cr-main.zip | 既存APIの参考。互換仕様の基準にはしない |
| SHA-256 | `eb261d630663cd3f867b66e6388f811c07d0c411987062af1e4c4f298ecbe118` |

Rust側の調査箇所:

- `d4/src/header.rs`・`dict.rs`: メタデータ、denominator、辞書、bit width。
- `d4/src/ptab/bit_array.rs`: packed table、最大コード、K=0、分割。
- `d4/src/stab/sparse_array/{record,record_block,compression,reader,writer}.rs`: RangeRecord、圧縮、フレーム。
- `d4-framefile/src/{directory,blob,stream,randfile,mapped}.rs`: コンテナ、copy、位置指定I/O。
- `d4/src/d4file/{reader,writer,track,merger}.rs`: 単一/複数トラック、Builder、分割、merge。
- `d4/src/ssio/{reader,view,http}.rs`: 非mmap読み取り、HTTP Range、領域view。
- `d4/src/index/{mod,sfi}.rs`・`index/data_index/{mod,data}.rs`: SFI、sum、精度と境界補完。
- `d4/src/task/{mod,sum,mean,histogram,value_range,perc_cov,vector,context}.rs`: 型付きタスク、統計、並列。
- `d4tools/src/{create,stat,index,merge,show}`・`d4tools/src/lib.rs`: 辞書推定、外部入力、表示とスケーリング。
- `d4binding/src/{api,stream}.rs`: 既存d4.crが受け継いだカーソルとC APIの制約。

upstream: [38/d4-format](https://github.com/38/d4-format)。リンク先masterの将来の状態ではなく、上記archiveを本計画の調査基準とする。

### Crystal公式文書

- [Iterator](https://crystal-lang.org/api/1.21.0/Iterator.html): ブロックなしでIteratorを返す標準的な入口。
- [Enumerable#sum](https://crystal-lang.org/api/1.21.0/Enumerable.html): 初期値による集計型の明示。
- [IO](https://crystal-lang.org/api/1.20.2/IO.html): seekはすべてのIOで利用可能とは限らない。
- [Compress::Deflate::Reader](https://crystal-lang.org/api/1.17.0/Compress/Deflate/Reader.html): raw DEFLATEのIOインターフェース。
- [Zlib](https://br.crystal-lang.org/api/Zlib.html): 圧縮エンジンのシステムライブラリ依存。
- [Crystal 1.21 parallelism](https://crystal-lang.org/reference/1.21/guides/parallelism.html): Execution Contextsと明示的なCPU並列化。
- [Crystal 1.21 release](https://crystal-lang.org/2026/07/16/1.21.0-released/): Execution Contextsが既定となった版。

### メモリ効率レビューで追加確認した一次資料

- [Crystal 1.21 Reference](https://crystal-lang.org/api/1.21.0/Reference.html): classのnewはheap上のinstanceを確保する。
- [Crystal structs](https://crystal-lang.org/reference/1.21/syntax_and_semantics/structs.html): 小さな値型、コピーとmutable structの注意点。
- [Crystal 1.21 Slice](https://crystal-lang.org/api/1.21.0/Slice.html): pointerからのviewはpayloadを確保しないが、size指定constructorはGC heapを確保する。
- [Crystal 1.21 Pointer](https://crystal-lang.org/api/1.21.0/Pointer.html): 要素の内部pointer情報に基づくGC allocation。
- [Crystal closures](https://crystal-lang.org/reference/1.20/syntax_and_semantics/closures.html)・[Proc](https://crystal-lang.org/api/1.21.0/Proc.html): 捕捉・escapeしたcontextの割り当てを確認する根拠。
- [Crystal 1.21 GC::Stats](https://crystal-lang.org/api/1.21.0/GC/Stats.html): total_bytesとheap_size/free_bytesの違い。
- [Crystal 1.21 DEFLATE Reader](https://crystal-lang.org/api/1.21.0/Compress/Deflate/Reader.html)・[Writer](https://crystal-lang.org/api/1.21.0/Compress/Deflate/Writer.html): wrapperの公開機能と、engine再利用を当然視しないための確認。
- [zlib manual](https://zlib.net/manual.html): inflateReset/deflateResetによる内部状態の再利用。

Rust側の追加確認は`index/sfi.rs`のraw bufferとitemsへのcopy、`index/data_index/mod.rs`の全blob読取と全index_result保持、`stab/sparse_array/compression.rs`のbuffer交換とcompressor.reset、`record_block.rs`の展開buffer生成である。Rustのメモリ構造をそのままCrystalへ移すことが最適とは限らないため、互換性と割り当て戦略を分けて検討した。

このPLANはソース読解と公式文書に基づく設計であり、Crystal版の実装・コンパイル・ベンチマークを完了したという報告ではない。
