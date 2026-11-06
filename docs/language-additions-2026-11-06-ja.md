# Dua 言語・標準ライブラリの追加（2026-11-06）

PC内の現行作業ツリーに、次の10件をこの順で追加しました。周辺ツール整備を項目数には含めません。

|順|追加|使い方と動作|
|---|---|---|
|1|JSON読込|`json.decode("{\"hp\":100}").hp`。不正JSON、64bit整数範囲外、非有限値を拒否。|
|2|文字列分割・結合|`string.join(string.split("a,b",","),"/")` → `"a/b"`。区切りはリテラル文字列。空要素を残し、空区切りは拒否。|
|3|安定ソート|`sorted([3,1,2])`。元の配列を変更しない。同種の整数・有限浮動小数点数・文字列、または `sorted(values,(any a,any b)=>a.key<b.key)`。比較関数はboolを返す。|
|4|畳込み|`reduce([1,2,3],0,(int acc,int value)=>acc+value)` → `6`。左から順に処理し、空配列は初期値。|
|5|Unicode文字配列|`utf8.chars("猫😀")` → `["猫","😀"]`。コードポイント単位。結合文字のまとまり単位ではない。|
|6|null時の代替値|`value ?? fallback`。右辺は左辺がnullのときだけ評価。0・false・空文字はそのまま。右結合。|
|7|null条件付きアクセス|`actor?.position?.x`、`actor?.move(expensive())`。nullの受信先ではnullを返し、引数も評価しない。`?.` を含む代入先は不可。非nullに存在しないメンバーのエラーは隠さない。|
|8|名前付き引数|`int f(int a=1,int b=2){return a+b;} f(b:4)`。Dua関数が対象。呼出し側の記述順に評価し、既定式は宣言順。位置引数は名前付き引数より前。未知名・重複・可変長引数の名前指定は拒否。|
|9|参照引数|`void bump(ref int n){n+=1;} int n=0; bump(n);`。変数の再代入を呼出し元へ反映。別のref関数への転送とコルーチンに対応。型は厳密一致。既定値・lazy併用・可変長・一時値・メンバー・添字・D native refへの橋渡しは対象外。|
|10|後始末|`try { work(); } finally { cleanup(); }`、`try/catch/finally`。通常終了・return・break・continue・例外・自然終了するコルーチンで後始末。finallyから外へreturn/yield/break/continueは不可。|

`map` と `filter` は従来からのDua標準関数です。配列・通常テーブルを対象にし、グローバル関数、UFCS、`table.map` / `table.filter` として利用できます。今回の10件には数えていません。`reduce` のコールバックは常に `(accumulator,value)`、`sorted` は `(left,right)` で、既存map/filterの引数調整規則は変更していません。nativeコールバック境界からのyieldには対応しません。

`finally` は予約語を増やさずtry文の後で解釈します。従来の `finally` という変数・関数・型名を維持します。実行制限を受けた後始末には別の上限（1024ステップ・追加呼出し深度16）を設け、元の実行制限を最終エラーとして保ちます。中断されたコルーチンをホストが破棄／module contextを強制closeする既存の経路は、後始末を実行するキャンセル処理には変更していません。

## 整数から浮動小数点数への暗黙変換

`double x=1;`、`double f(double x){return x;} f(1)`、doubleの戻り値、再代入、型付き配列要素・AAの要素／キー・table/structフィールドに整数を渡せます。`float` / `real` もDuaの既存のdouble保存形式を使います。逆向きのdouble→int、文字列やboolへの暗黙変換は追加していません。

`alias Number=int|double; Number x=1;` と `alias Number=double|int; Number x=1;` はどちらも整数のままです。候補全体への直接一致を先に確認し、それで受理できない場合だけ浮動小数点数へ変換します。`1 is double` は引き続きfalseです。`ref double` にint変数は渡せません。

大きい整数の変換はDの整数→浮動小数点数の規則と、ホストの `cast(double)` を使います。値によって精度は失われます。DMDの実測例は `9007199254740993` → `9007199254740992`、`long.max` → `9223372036854775808` です。変換先が不要なUnionやauto変数では丸めません。[D言語の型変換仕様](https://dlang.org/spec/type.html)を参照。

`auto original=[1,2]; double[] converted=original;` はconverted用の要素を準備し、originalの整数を書き換えません。同じ要素型の配列同士の代入は従来どおり共有します。既に別の型を持つAAの全体再注釈、および配列全体のUnionから変換先配列分岐を選ぶ処理は追加していません。

## ZsDからDua標準へ移した関数

- `math.PI`、`exp/fmod/fmax/fmin/sqrt/log/sin/cos/tan/clamp`、`algorithm.clamp`。
- `string.format`。数値の型を保ち、Dのフォーマット指定・位置指定を使用。値表示の再帰と要素数を制限。
- `random.Random`、`uniform01/unpredictableSeed/seed/uniform/choice/dice`。従来のseed・区間指定・状態の参照とsaveを維持。乱数状態はengineごとに独立。

Dua単体で `import math; import algorithm; import string; import random;` が使えます。mathとstringは従来のグローバル標準テーブルからも利用でき、Randomのグローバル別名はrandom読込時にfallbackとして追加します。ホストが登録した同名の値・モジュール、明示登録ソース、ファイル、ローダーは標準の自動読込より優先します。ZsDの登録箇所はDua標準モジュールへ委譲し、二重実装をなくしました。

ZsDのprint出力先、シーン、描画、入力、物理、アセット、ウィンドウ、Vec2等はホスト固有のため移していません。



D nativeのref数値引数にも整数→doubleの暗黙変換を適用しません。Dua関数のrefとDのrefバインディングは別の経路であり、D側の既存の変換用一時値・書戻し仕様は変更していません。



## 検証結果

- `dub build --compiler=dmd` 成功。変更の各段階で実行。
- `dub test --compiler=dmd` および `dub test --compiler=ldc2`: 最終ソースで各45モジュール成功。
- エディタのチェッカーを現行ソースから再ビルドし、`npm test`: 145件成功。
- 現行ZsDと現行Duaを参照する隔離したLDC実行ファイルで、数学・書式化・乱数・暗黙変換・print出力先の実行テスト成功。
- 同じ隔離実行ファイルでZsD補完テスト成功（API、セッション呼出し、旧名、正規化名、scene self、autosave除外、読取専用アセット、更新／移動／削除）。

通常版Dua/ZsD実行ファイルは置換せず、隔離環境で検証しました。
