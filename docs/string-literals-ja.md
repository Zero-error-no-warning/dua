# 文字列のエスケープと補間式

通常文字列と `i"..."` の文字部分は、次のエスケープを解釈します。

| 表記 | 値 |
| --- | --- |
| `\n` | 改行 LF |
| `\r` | CR |
| `\t` | タブ |
| `\0` | NUL |
| `\"` | ダブルクォート |
| `\\` | バックスラッシュ |

未定義のエスケープ（例 `\q`、`\u`、`\x`）は、バックスラッシュの位置でエラーです。
文字部分には実改行を書けません。改行値は `\n` で記述します。
引用符は従来どおりダブルクォートのみです。

```dua
auto message = "first\nsecond\t\"quoted\"";
auto path = "C:\\new\\test.txt";
auto text = i" $("test") "; // " test "
auto nested = i"$(i"inner $("value")")";
auto literal = i"$$(text)"; // "$(text)"
auto multilineExpression = i"$(1 // コメント中の ) は無視
    + 2)";
```

`$(...)` 内では通常の文字列式が使えます。式内の文字列中の括弧、エスケープ引用符、入れ子補間、`#` / `//` 行コメント、入れ子可能な `/+ ... +/` コメントを区別します。
式中では改行できます。文字部分の実改行許可には拡張していません。
`$$` のドル記号エスケープと、カンマ区切りの式を左から評価して文字列化する既存仕様を維持します。
`\$` は対応しません。ドル記号を補間開始にしない場合は `$$` を使います。
文字列キー、import名、文字列リテラル型も通常文字列と同じ復号を行います。

## 旧ソースとの互換性

従来のバックスラッシュは常に文字どおりの値でした。
旧 `"C:\new\test"` は、新仕様では改行とタブを含む値になります。
`"C:\fruit"` のような未定義エスケープを含む旧パスはエラーになります。
Windowsパスは `"C:\\new\\test"` または `"C:/new/test"` に移行してください。
以前の `"\\"` は2文字でしたが、新仕様では1文字です。
raw文字列、Unicode/16進数エスケープ、単引用符文字列は今回追加しません。

## エディタとの整合

standaloneのVS Code拡張はトークン解析・文字列マスク・TextMate文法・パス/アセット文字列の補完挿入を同じエスケープ規則に対応済みです。診断用dua-checkもstandalone/vendor各候補から個別に再ビルドしています。原本への反映や拡張のインストールはまだ行っていません。

## 文字列の添字

`s[i]` はDの `string` と同じ、0始まりのUTF-8コードユニット（バイト）単位です。
`s.length`、`length(s)`、`len(s)`、`string.len(s)`、添字内の `$` は従来どおりバイト数です。
Duaには `char` 専用のスカラー型がないため、Dの `immutable(char)` の数値を `int`（0〜255）で返します。

```dua
string text = "A日😀";
auto bytes = text.length; // 8
auto ascii = text[0]; // 65
auto lead = text[1]; // 230 // 「日」のUTF-8先頭バイト
auto last = text[$ - 1]; // 128 // 絵文字の末尾バイト
```

整数添字とD同様のbool添字（false=0、true=1）を受け付け、浮動小数点や文字列への暗黙変換はしません。
負数・長さ以上・空文字列の添字は範囲外エラーです。負数を末尾からの位置とは解釈しません。
文字列はimmutableで、添字への代入・複合代入はエラーです。通常評価とコルーチンで同じ動作になります。
日本語・絵文字・結合文字は複数バイトになり得ます。`utf8.len(s)` はUnicodeコードポイント数のままです。
文字列のスライス・foreachはこの追加の対象外で、未対応のままです。

文字列の `.length` は配列と同じ組み込みプロパティとして優先します。従来UFCSの同名関数で上書きしていた場合も、常にバイト数です。明示的な `length(s)` 関数呼出しの名前解決は変更しません。

## Unicodeコードポイントの数と取得

```dua
string text = "あいう";
auto bytes = text.length;    // 9（D stringと同じバイト数）
auto firstByte = text[0];    // 227（UTF-8の先頭バイト）
auto chars = count(text);    // 3（D std.algorithm.countと同じ）
auto first = charAt(text, 0); // "あ"（string）
auto same = first == "あ";   // true
auto last = text.charAt(2);  // "う"（UFCSも使用可能）
auto total = text.count;     // 3（text.count()も同じ）
```

`count(string)` はDの `std.algorithm.searching.count` を呼び、全コードポイントを数えます。
`charAt(string, index)` は0始まりで、`byDchar.drop(index).front` に相当するコードポイントをUTF-8のstringとして返します。
Duaに `char` / `dchar` 専用型はないため、1文字stringを使って比較・連結できます。
結合文字やZWJ絵文字の「見た目の1文字」ではありません。たとえば `é` は `e` と結合アクセントの2コードポイントです。

`count` は入力全体に比例する時間、`charAt` は先頭から指定位置までに比例する時間が必要です。
文字列全体のデコード配列・キャッシュは作りません。取得結果は最大4バイトです。
先頭から各位置を毎回 `charAt` で取得するループは合計で二次時間になり得ます。

空文字列のcountは0です。charAtの負数・範囲外はエラーで、nullや空文字列にはしません。
不正UTF-8に対しても、countはDのcount(string)、charAtはDのbyDcharの既定置換規則をそのまま使います。charAtは不正な並びをU+FFFDへ置き換えて返します。Dのcount(string)の高速カウントとbyDcharの置換単位は不正入力では異なることがあり、例としてバイトFF 80はcountが2、charAtで取得できる置換文字は1個です。不正入力のcountをcharAtの有効範囲と見なさないでください。
これは元のバイト列を書き換える操作ではありません。入力はstring、添字は整数（boolも0/1として可）に限定します。
既存の `utf8.len` と他の文字列API、foreach・スライスは変更しません。
同名のユーザー関数・変数やtableメンバーがある場合は既存の名前解決を優先します。
