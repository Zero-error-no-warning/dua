module dua.coroutineInterop;

import dua.value;
import dua.coroutine : inStacklessExecution;
import std.exception : enforce;

// Duaを組み込む同一package内のアダプタ用。スクリプトAPIは増やしません。
// 同期Dコールバックを中断する代わりに、Dへ戻った後で再開判定だけを保持します。
package(dua) abstract class CoroutineWait : CallableValue {
    private CallableValue fallback;
    this(string name,CallableValue fallback){super(name);this.fallback=fallback;}
    abstract bool delegate() beginWait(Value[] args);
    override size_t expectedArity() const{return fallback.expectedArity();}
    override size_t minimumArity() const{return fallback.minimumArity();}
    override size_t maximumArity() const{return fallback.maximumArity();}
    override bool acceptsArity(size_t count) const{return fallback.acceptsArity(count);}
    override Value invoke(Value[] args){
        enforce(!inStacklessExecution(),"Cannot yield across a synchronous native callback boundary");
        return fallback.invoke(args);
    }
}

// 結果を写像するZsDの反射ラッパーは、再開可能な呼出し先と後処理を明示します。
// 任意のD delegateを再開可能と見なすことはありません。
package(dua) abstract class CoroutineWrapper : CallableValue {
    this(string name){super(name);}
    abstract CallableValue coroutineTarget();
    abstract Value coroutineResult(Value result);
}
