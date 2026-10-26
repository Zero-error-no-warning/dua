# UFCS の括弧省略

## 仕様

`int doubledDamage(WeaponStats stats) { ... }` に対する
`weapon.doubledDamage` は `weapon.doubledDamage()` と同じ結果を返す。
受け手式を一度評価し、受け手一つで呼べる関数だけを自動呼び出しする。
同じスコープの関数名を探す `resolveUfcs` と通常の `invokeFunctionValue` を使う。

```dua
table WeaponStats { int damage; }
int doubledDamage(WeaponStats stats) { return stats.damage * 2; }
auto weapon = WeaponStats { damage = 12 };
return weapon.doubledDamage == 24 && weapon.doubledDamage() == 24;
```

優先順位:

1. 配列/連想配列の既存プロパティ (`length`、AA の `keys`/`values`)
2. 既存 getter、直接メンバー、`__index` の既存プロパティ解決
3. スコープ/グローバルの既存 UFCS 解決。引数数が既知で、受け手一つを受け取れる場合だけ評価
4. 従来のプロパティエラー

直接関数メンバーの `acceptsArity(0)`、モジュール export 関数を値として取得する動作は維持。
明示 `receiver.fn(args)` は既存 `callMethodOrUfcs` 経路を使い、省略式評価を通さない。
そのため返り値が関数でも二重呼び出ししない。

## 引数と関数値

- 必須の追加引数がある関数は省略式で呼ばない。`receiver.fn(extra)` を使う。
- 関数値は `auto f = fn;` / `auto f = module.fn;` で取得する。
  `receiver.fn` を受け手に束縛した関数値として新たに扱う機能は追加しない。
- D の bindFunc の既定引数・variadic と script の variadic は、既存の arity 情報を使う。
- overload は各候補の arity を調べ、引数数に穴がある集合でも勝手に呼ばない。
  実際の型別候補選択・曖昧エラーは従来の呼び出し処理に委ねる。
- 引数数が不明な raw bindNative/カスタム CallableValue は自動実行しない。
  そのような組込み関数の UFCS は明示 `()` が必要。
- table 内のメソッド宣言は今回の対象外。

## 静的解析と拡張

protocol/API/schema の追加なし。既存関数の parameterTypes/variadic/type を利用できる。
checker はスカラー・配列/AA等、動的メンバーが UFCS を隠さない受け手について、
既知の受け手一引数で呼べる関数の戻り値を推論する。
table/host の任意追加 field・メタテーブルが名前を隠せる場合は `any` を維持し、
実行時の優先順位と検査に委ねる。明示呼び出しと import の既存規則を変えない。
拡張の独自式推論も同じ優先順位と保守的境界に合わせる。

## 確認

`tests/ufcs_property.d` と `tests/ufcs_property_cases.json` の20条件を
typeCheck 無効/有効の両方で実行（40条件）。メンバー・getter・__index・明示呼び出し・
関数値・import・local scope・overload・既定引数・variadic・配列/AAを確認。
table の宣言文法、named constructor と型同一性は変更しない。
