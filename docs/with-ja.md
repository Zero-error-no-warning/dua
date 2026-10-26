# 2つの with

## 型の共通メタテーブル

`with meta` 付き型宣言はモジュールの最上位だけで使えます。関数の実行ごとに共通設定が上書きされることを避けるためです。従来の with なしローカル型は引き続き使えます。

```dua
auto numberMeta = {};
table Number with numberMeta { int value; }
numberMeta["opBinary+"] = (any a, any b) => Number { value = a.value + b.value };
auto sum = Number { value = 2 } + Number { value = 3 };
```

`struct Number with numberMeta { ... }` も同じ指定を使えます。struct は自動コンストラクタ `Number(...)` で生成し、値コピーの規則は従来どおりです。

meta の指定は識別子または `module.meta` のような修飾参照です。型宣言を実行した時に一度だけ、非nullのscript tableとして解決します。後からmeta変数を再代入しても型の設定は変わりません。同じmeta実体の内容を変更すると、既存・新規の個体へ反映されます。空metaを先に用意し、型宣言後に演算関数を登録すると相互参照できます。前方の未初期化参照はエラーです。

共通metaは列挙・JSON・フィールド数・型同一性へ混ぜず、内部に保持します。alias/import経由の同じ型にも適用されます。基底tableのフィールドspreadだけからmetaを自動継承しません。未指定型の従来動作は維持します。

直接の演算キーが最優先で、明示した `__meta` が宣言metaより優先です。`setmetatable(table, meta)` は個体のmetaを置き換え、`setmetatable(table, null)` は解除します。`getmetatable(table/struct)` は実効metaを返します。structへのsetmetatableは今回追加しません。

モジュールの型宣言は既存の通常宣言と同じ共有・初期化単位です。metaは最初の初期化文脈で解決され、追加instanceで再評価されません。meta内の関数は既存のクロージャの文脈・寿命に従います。個体/instance別の状態はmetaに自動分離されないため、table個体への明示設定や通常のinstance変数を使ってください。

## 式の対象を指定する

共有meta内のcallbackも既存の寿命規則に従います。初期化元の文脈が終了したcallbackを別instanceへ自動で付け替えません。共有する演算関数はPlayのroot等、必要な期間存続する文脈で初期化してください。

```dua
auto vec = { x = 3, y = 4 };
int x = 7;
auto distanceSquared = with(vec) .x * .x + .y * .y + x; // 32
auto sum = (with(vec) .x) + x; // 10
```

対象を一度だけ評価し、先頭ドットのメンバーだけがその対象を参照します。裸の名前は通常どおり解決します。withの後ろの式全体が本体で、括弧で範囲を区切れます。引数のカンマや文のセミコロンも境界です。

入れ子では最内側の対象を使用します。対象のgetter・メソッド・連鎖アクセスは既存のメンバー処理に従います。先頭ドットのメンバーが見つからなくても、外側の変数やUFCS関数へfallbackしません。with外での先頭ドットはエラーです。

with内で定義したクロージャはその字句対象を保持します。外で定義した関数へ動的に対象を渡す機能ではありません。Fiberの中断・再開でも別のwith対象が混線しないよう、通常の実行環境へ保持します。グローバルな現在対象stackは使いません。

先頭ドットを用いた代入左辺（`.x = ...` など）は今回未対応です。通常の名前付き変数への代入や、対象のメソッドが持つ既存の副作用は変更しません。
