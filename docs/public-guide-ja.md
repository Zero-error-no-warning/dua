# Dua 入門ガイド

このガイドでは、Dua を初めて使う人が **D アプリケーションへ組み込み、値と関数を渡し、失敗を安全に扱う** ところまでを順に説明します。言語機能の全一覧は[言語リファレンス](language-reference-ja.md)、D API の詳細は[埋め込み API リファレンス](embedding-api-ja.md)を参照してください。

## 1. Dua とは

Dua は D 製アプリケーションに組み込む軽量スクリプトランタイムです。設定だけでは表現しにくいルールや拡張ロジックを、ホストアプリを再ビルドせず差し替えたい用途に向きます。独立した汎用 VM や他言語との互換実装ではありません。

典型的な役割分担は次のとおりです。

- **D 側**: ファイル、ネットワーク、永続化などの権限を持つ処理とデータを用意する。
- **Dua 側**: 公開された値と関数を組み合わせ、アプリ固有の判断や計算を記述する。
- **境界**: `Dua.ScriptEngine` と `Dua.Value` で、公開する機能を明示的に限定する。

## 2. ビルドして動作を確認する

必要なものは DUB と LDC (`ldc2`) です。リポジトリのルートで次を実行します。

```bash
dub build --compiler=ldc2
dub test --compiler=ldc2
```

ライブラリとして利用する場合は、DUB プロジェクトの依存関係に Dua を追加し、D コードから `import dua;` します。このリポジトリ自身は既定の `library` configuration でライブラリを生成します。

## 3. 最小の埋め込み

```d
import dua;
import std.stdio : writeln;

void main()
{
    auto engine = new Dua.ScriptEngine();
    auto result = engine.run(q{
        auto greeting = "Hello";
        return greeting ~ ", Dua!";
    });

    writeln(result.toHostString()); // Hello, Dua!
}
```

`run` はソースを解析して実行し、トップレベルの `return` 値を `Dua.Value` として返します。戻り値がなければ `null` です。`Value` からは `toInt()`、`toFloat()`、`toHostString()`、`truthy()` などで値を取り出せます。

## 4. D の値をスクリプトへ渡す

`bindAuto` はプリミティブ、配列、文字列キーの連想配列を自動変換します。`engine["name"] = value` も同じ変換を行う短縮記法です。

```d
auto engine = new Dua.ScriptEngine();
int bonus = 5;
engine.bindAuto("base", 40);
engine["bonus"] = bonus;

auto result = engine.run("return base + bonus;");
assert(result.toInt() == 45);
```

すでに `Dua.Value` がある場合は `bind` を使います。

```d
engine.bind("tags", Dua.Value.from(["safe", "fast"]));
```

## 5. D の処理を関数として公開する

`bindNative` のコールバックは `scope const(Dua.Value)[]` を受け取り、`Dua.Value` を返します。引数の個数と型はホスト側で検査してください。

固定シグネチャのD関数、delegate、型付きlambdaには `bindFunc` を使用できます。同名のオーバーロードはDuaの実引数型から選択され、reflectされたクラス・構造体のメンバー関数にも同じ選択規則が適用されます。

```d
engine.bindFunc!plusOne("plusOne");
engine.bindFunc!((long value) => value + 1)("inlinePlusOne");
```

```d
engine.bindNative("clamp", (scope const(Dua.Value)[] args) {
    assert(args.length == 3);
    auto value = args[0].toInt();
    auto low = args[1].toInt();
    auto high = args[2].toInt();
    return Dua.Value.from(value < low ? low : value > high ? high : value);
});

assert(engine.run("return clamp(120, 0, 100);").toInt() == 100);
```

信頼できないスクリプトへ、任意パスの読み書きやコマンド実行のような強い権限をそのまま公開しないでください。標準ライブラリにも `io.readFile`、`io.exists`、`os.getenv` があるため、実行環境自体の権限分離も検討してください。

## 6. スクリプトを段階的に書く

```D
alias Character = {
    string name;
    int hp;
};

int damage(Character target, int amount) {
    target.hp = target.hp - amount;
    if (target.hp < 0) {
        target.hp = 0;
    }
    return target.hp;
}

Character hero = { name = "Ada", hp = 30 };
return damage(hero, 8);
```

重要な基本ルールは次のとおりです。

1. 文末には原則 `;` が必要です。
2. 文字列リテラルはダブルクォートです。
3. `auto` と型付き変数には初期値が必要です。
4. 配列とテーブルは参照型です。独立した浅いコピーには `[...array]` / `{...table}` を使います。
5. 動的に扱う箇所では `any`、境界を検査したい箇所では `int` などの型を使います。

## 7. 失敗を安全に受け取る

ユーザーが編集するソースには、例外を送出する `run` より `runSafe` が適しています。

```d
auto outcome = engine.runSafe("return missingName + 1;");
if (!outcome.ok)
{
    writeln(outcome.errorKind);
    writeln(outcome.errorMessage);
    foreach (frame; outcome.stackTrace)
        writeln(frame);
}
```

さらに実行予算と事前型検査を設定できます。

```d
auto options = Dua.RunOptions();
options.typeCheck = true;
options.limits.maxSteps = 100_000;
options.limits.maxCallDepth = 128;

auto outcome = engine.runSafe(source, options);
```

`0` の制限値は無制限です。ステップは安全制御用の概算単位で、処理時間や VM 命令数ではありません。またネイティブ関数内部の処理はカウントされないため、必要ならホスト側でも時間・メモリ・I/O を制限します。

## 8. 複数ファイルへ分ける

D 側でモジュールを登録し、スクリプトから読み込めます。

```d
engine.registerModule("game.rules", q{
    export int addBonus(int score) { return score + 10; }
});

auto result = engine.run(q{
    import game.rules as rules;
    return rules.addBonus(32);
});
assert(result.toInt() == 42);
```

`require("game.rules")` も利用できます。モジュールはエンジン単位でキャッシュされ、`clearModuleCache()` で破棄できます。未登録モジュールは既定で `?.dua`、`?/init.dua` を検索します。

## 9. 次に読むもの

- スクリプトを書く: [言語リファレンス](language-reference-ja.md)
- 型変換、`bindType`、ファイル実行、エラー結果: [埋め込み API リファレンス](embedding-api-ja.md)
- 実装と公開ファサードを確認する: `source/dua/package.d`、`source/dua/runtime.d`、`source/dua/value.d`

## 10. 運用チェックリスト

- [ ] `dub build --compiler=ldc2` と `dub test --compiler=ldc2` が通る。
- [ ] 通常の失敗経路に `runSafe` / `loadSafe` を使っている。
- [ ] 信頼できないコードに `maxSteps` と `maxCallDepth` を設定している。
- [ ] 公開するネイティブ関数とホスト権限を最小化している。
- [ ] モジュール検索パスとスクリプトの読み込み元を管理している。
- [ ] `Value` やエンジンに巨大な参照を不要に保持していない。
