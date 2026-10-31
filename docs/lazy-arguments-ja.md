# lazy引数（段階的対応）

通常の関数・ラムダで必須引数を `lazy T name` と宣言できます。

```dua
int twice(lazy int value) { return value + value; }
int ignore(lazy int value) { return 0; }
```

引数の式は使用されなければ評価されず、読み出すたびに呼出し元の環境で
再評価されます。値のキャッシュは行いません。呼出し元のローカル変数、
モジュール、ソース位置を保持します。閉じたモジュールの式は実行できません。
型検査を無効にした場合も遅延評価します。

現段階ではlazy引数への代入、lazy既定引数、lazy可変長引数は明示的に拒否します。
関数値の型表記にlazyを含む宣言は未対応です。
呼出し先・receiverの解決後に通常引数を左から評価します。以前の実装では
引数を先に評価していたため、両方に副作用のある式は評価順に注意してください。

D nativeの `lazy` 引数にも、引数式を評価せずに渡します。Dが引数を読むたびに
式を評価します。nativeの既定式は既存の宣言情報から読出し時に評価します。

lazy候補を含むnative overloadは、未評価の式の型で選択します。
`f(int)` / `f(lazy int)` は曖昧エラーです。`int` / `lazy string`、
`lazy int[]` / `int[] delegate()` は区別できます。型を推定できない動的な式は
先に実行せず、明示castや型付き関数を案内するエラーにします。
数値変換の順位・動的table・汎用delegate型の詳細な適合判定はDの完全な型検査では
ありません。同点候補を拒否し、Duaの既存native変換は引数の使用時にも検査します。
nativeのlazy可変長引数は未対応です。nativeから任意に保存されたlazy thunkを
異なるthreadで呼ぶことは対象外です。モジュールを閉じた後は評価できません。

native補完署名の各parameterには `lazy: true/false` を出力します。
