# Nullable 配列とハンドル代入

## 対象

Dua の `T[]`、`V[K]`、汎用 `array` / `associativeArray` を既定 nullable とする。
table の既定 nullable、明示的な `T & !null`、値型の null 拒否は維持する。
構文/API v1 のフィールド追加はない。既存の配列/AA型文字列と `(<T> & !null)` を使う。

```dua
int[] array1 = [1, 2, 3];
int[] array2 = [4, 5, 6];
int[] pointArray = null;
pointArray = array1;
pointArray[0] = 9;          // array1[0] も 9
pointArray = array2;       // array1 のハンドルは付け替えない
```

同じ要素型へ準備済みの配列を代入・引数・戻り値・field で受け渡すと、要素を共有する。
配列ハンドルの付け替えや append 後の長さは各変数に属する。
未注釈値への新しい要素型の付与や型の正規化は、従来どおり検査用コピーを作る場合がある。
すべての異なる注釈間の代入を無条件に共有する変更ではない。

## null、空、内容比較

```dua
int[] p = null;
int count = p.length;       // 0
foreach (item; p) { }       // 0回
bool equalEmpty = p == [];  // true
bool nilHandle = p is null; // true
p ~= 1;                    // [1]、p は非 null ハンドルになる
```

`==` は長さと要素を比較し、null 配列と空配列を等しいとする。
raw `null == []` も空コンテナとの内容比較として真。空 AA と null の内容比較も同様。
配列と AA そのものは別の値種別で、両者の空コンテナ同士を同一の型にするものではない。

null ハンドルの状態は別に保持する。`int[] & !null p=[];` は有効で、`p is null` は偽。
nullable の型付き null 配列は配列の長さ/反復を持ち、`is null` では真となる。
Dua の `is` は既存の型判定構文であり、D の一般的な値同一性比較 `a is b` は追加しない。

型付き null の0番目の添字は通常の `Array index out of range`。
空 AA の存在しないキーは既存の `Associative array key not found`。
null 配列の `[0..0]` は長さ0の null ハンドルを保つ。

`any x=null; x.length` や table 型の null に配列操作を付与しない。
型注釈・cast により配列/AAと分かるコンテキストでのみ、null を型付きハンドルに準備する。
単一 alias と、nullable な候補が同じコンテナ種別に決まる union も準備できる。
table と配列など異なる参照種別が混じる曖昧な union の null は汎用 null に残す。

## コンテナと要素の非 nullable

```dua
table Item { int count; }
Item[] & !null requiredContainer = []; // コンテナ自体が非 null
(Item & !null)[] optionalContainer = null;
optionalContainer = [Item { count = 1 }]; // 要素だけ非 null
```

- `int[] & !null p=null` と、null ハンドルを非 nullable に cast/再代入する操作は拒否。
- `int[] p=[null]` は引き続き拒否。コンテナの null 許可と値型の要素制約は別。
- `int[][] p=[null]` の内側の配列は nullable。各要素も非 null にするなら `(int[] & !null)[]`。
- `int[string]` 等の AA も同じ非 null コンテナ/値型制約を持つ。
- nullable field の initializer 指定は引き続き必須。
- 既存の直接宣言 `int[] p;` / `int[string] p;` は null ハンドル初期化にする。
  非 nullable コンテナ、table や alias への新しい初期値省略構文は追加しない。
- 宣言・再代入・引数・戻り値・field・rawset・export snapshot で型付き null を準備する。
- 静的検査は nullable 変数を非 nullable と証明するフロー解析を追加しない。必要なら明示 cast を使う。

## AA と D ホスト境界

null AA は長さ0、keys/values は空、foreach は0回。最初の挿入で非 null になる。
null AA ハンドルをコピーしてから片方へ初挿入しても、もう片方の null を変えない。
既存の非 null AA のコピーは従来どおり内容を共有する。

D の動的配列/AAの引数には null を渡せる。D の固定長配列、数値、struct、string の null 拒否を維持。
D との引数変換は従来の materialize/copy であり、D のメモリと Dua の要素共有までは保証しない。
D から戻った配列の既存の配列化規則は維持し、D の null slice のポインタ情報を新たに公開しない。

JSON と script literal は型付き null コンテナを `null`、非 null の空配列を `[]` として出力する。
内容比較と、シリアライズ時の null ハンドル状態は区別する。

## 互換性と確認

従来 NULL拒否が必要だった配列/AAの境界は `& !null` に移行する。
同じ型の型付き配列代入は共有するため、独立コピーを前提にしていた箇所は `[...source]` 等で明示コピーする。
既存の空配列の長さ/真偽、要素制約、named table の型同一性、UFCS は維持する。
非空スライスの既存コピー挙動、容量最適化、D ABIや参照同一性演算子は今回変更しない。

独立実行39境界×型検査有無の78条件、checker/API26条件を限定確認。
比較とハンドル共有の基準は [D公式配列仕様](https://dlang.org/spec/arrays.html#array-comparison) と
[動的配列代入](https://dlang.org/spec/arrays.html#array-assignment) を参照。
