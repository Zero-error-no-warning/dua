# Dホスト型の添字代入

Duaの通常の単一添字代入 `object[key] = value;` は、Dのbound class/structに公開された具体的な`opIndexAssign`があれば、既存のnative変換・overload選択を通して`opIndexAssign(value, key)`を呼びます。値、キーの順です。戻り値は使いません。テンプレート全般の自動実体化は追加していません。

```d
void opIndexAssign(void delegate() action, string name) {
    setState(name, action);
}
```

このようなDメソッドを公開したStateMachineなら、Duaでは次のように登録できます。

```lua
auto machine = self.stateMachine();
machine["idle"] = () { /* 毎更新の処理 */ };
machine.changeState("idle");
```

状態登録・重複名等の意味はD側の実装に従います。代入だけで状態へ遷移するわけではありません。通常のメソッド呼出しは`machine.setState("idle", action)`で、引数順が逆です。

右辺の関数は既存のnative引数変換で`void delegate()`へ変換します。Duaの関数本体からDのdelegate型や一般テンプレートを新たに推論する機能ではありません。

- 配列・typed連想配列への代入、およびDua tableの`__newindex(self,key,value)`は従来どおりです。
- このD演算子の経路は、実際のD class/structに限定します。通常のDua tableに`opIndexAssign`というフィールドを作っても演算子にはなりません。
- `opIndex`での読取りは従来どおりです。
- 空添字、複数添字、sliceへの代入は対象外です。native indexed `+=`等も未対応として診断します。
- 引数の型が不適合なら、通常のnative関数呼出しと同じ変換・overloadエラーになります。receiverとキーは1回評価します。

実装は`source/dua/evaluator.d`、native判別は`source/dua/value.d`、回帰確認は`native_index_assignment_tests.d`を参照してください。`binding.d`のホスト側`engine["name"] = value`用演算子とは別の機能です。
