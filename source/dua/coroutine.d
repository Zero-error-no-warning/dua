module dua.coroutine;

import dua.binding : NativeCallable;
import dua.value;
import dua.ast : AstNode;
import dua.evaluator : ModuleContext, EvaluatorContext;
import dua.execution;
import dua.coroutineExecution : CoroutineFrame;
import std.exception : enforce;
import std.format : format;
import core.thread : Fiber;

package(dua) CoroutineState executingCoroutine;
package(dua) void* executingHostFiber;
package(dua) bool inStacklessExecution(){
    return executingCoroutine !is null&&executingHostFiber==cast(void*)Fiber.getThis();
}

// 各実行の続きはheap上に保存し、ネイティブスタックは所有しません。
package final class CoroutineState {
    ModuleContext context;
    EvaluatorContext evaluation;
    Value entryFunction;
    Value[] pendingArgs, yieldedValues, returnValues;
    bool started, dead, failed, running, suspended, abandoned;
    size_t nativeDepth;
    string errorMessage;
    Exception failure;
    AstNode node;
    string role;
    private CoroutineFrame[] frames;
    private size_t frameCount;
    void push(CoroutineFrame frame){
        if(frameCount==frames.length)frames.length=frameCount==0?8:frameCount*2;
        frames[frameCount++]=frame;
    }
    CoroutineFrame pop(){
        assert(frameCount>0);
        auto frame=frames[--frameCount];frames[frameCount]=CoroutineFrame.init;return frame;
    }
    bool hasFrames(){return frameCount!=0;}
    void releaseExecution(){
        frames=null;frameCount=0;entryFunction=Value.init;pendingArgs=null;
        node=null;role=null;evaluation=EvaluatorContext.init;
    }
}

package mixin template CoroutineImplementation() {
    private size_t nextCoroutineId=1;
    private CoroutineState[size_t] coroutines;
    private CallableValue coroutineYieldable;
    private EvaluatorContext* stacklessContext;
    private void* stacklessHostFiber;
    private CoroutineState activeCoroutine(){return cast(CoroutineState)evaluatorContext.activeCoroutine;}
    package(dua) Value createCoroutine(Value fn){
        enforce(fn.kind==ValueKind.function_,"coroutine.create(callback) expects function");
        auto state=new CoroutineState;
        state.context=currentModuleContext();state.entryFunction=fn;
        state.evaluation.moduleContext=state.context;
        state.evaluation.activeCoroutine=state;
        auto id=nextCoroutineId++;coroutines[id]=state;return coroutineHandle(id);
    }
    private Value coroutineHandle(size_t id){
        auto handle=Value.from(cast(Value[string])null);handle.setCoroutineId(id);return handle;
    }
    package(dua) CoroutineState requireCoroutineState(Value handle){
        enforce(handle.kind==ValueKind.table,"Coroutine handle must be a table");
        size_t id;enforce(handle.getCoroutineId(id),"Invalid coroutine handle");
        auto state=id in coroutines;enforce(state !is null,"Unknown coroutine handle");return *state;
    }
    private void closeCoroutines(ModuleContext ended){
        foreach(state;coroutines){
            if(state.context !is null&&state.context.belongsTo(ended)&&!state.running){
                state.dead=true;state.failed=true;state.errorMessage="Module context is closed";
                state.releaseExecution();
            }
        }
    }
    // Scene.exit用。実行中の自己exitは次のyield/returnまで進み、その後だけを破棄します。
    package(dua) void discardCoroutine(Value handle){
        auto state=requireCoroutineState(handle);state.abandoned=true;
        if(!state.running){
            state.dead=true;state.releaseExecution();state.context=null;
            size_t id;handle.getCoroutineId(id);coroutines.remove(id);
        }
    }
    package(dua) Value resumeCoroutine(Value handle,Value[] args){
        auto state=requireCoroutineState(handle);
        if(state.running)return Value.from([Value.from(false),Value.from("cannot resume running coroutine")]);
        if(state.context !is null&&!state.context.alive){
            state.dead=true;state.failed=true;state.errorMessage="Module context is closed";state.releaseExecution();
        }
        if(state.dead)return Value.from([Value.from(false),Value.from(state.failed?state.errorMessage:"cannot resume dead coroutine")]);
        auto previous=stacklessContext;auto previousFiber=stacklessHostFiber;
        auto previousExecution=executingCoroutine;auto previousExecutionFiber=executingHostFiber;
        auto options=evaluatorContext.currentRunOptions;
        stacklessContext=&state.evaluation;stacklessHostFiber=cast(void*)Fiber.getThis();
        executingCoroutine=state;executingHostFiber=stacklessHostFiber;
        state.evaluation.currentRunOptions=options;state.evaluation.executedSteps=0;
        state.evaluation.lastErrorStack=null;
        state.running=true;state.suspended=false;state.pendingArgs=args.dup;state.yieldedValues=null;
        scope(exit){
            state.running=false;stacklessContext=previous;stacklessHostFiber=previousFiber;
            executingCoroutine=previousExecution;executingHostFiber=previousExecutionFiber;
            if(state.abandoned){
                state.dead=true;state.releaseExecution();state.context=null;
                size_t id;handle.getCoroutineId(id);coroutines.remove(id);
            }
        }
        if(!state.started){
            state.started=true;
            coInvokeCallable(state,state.entryFunction,state.pendingArgs.dup,(Value result){state.returnValues=[result];});
        }
        while(state.hasFrames()&&!state.suspended){
            auto frame=state.pop();state.node=frame.node;state.role=frame.role;
            try frame.advance();
            catch(Exception error){
                auto node=state.node;
                error=withSourceContext(error,evaluatorContext.sourceName,node is null?"":format("%s:%s",node.line,node.column),state.role.length?state.role:"coroutine",
                    node is null?0:node.line,node is null?0:node.column);
                evaluatorContext.lastErrorStack=evaluatorContext.callStack.snapshot();
                bool caught;
                while(state.hasFrames()){
                    auto pending=state.pop();
                    if(pending.unwind !is null)
                    {
                        auto previousUnwinding = evaluatorContext.unwindingException;
                        evaluatorContext.unwindingException = error;
                        try pending.unwind();
                        catch (Exception cleanup)
                        {
                            if (cast(ExecutionLimitException) error is null)
                            {
                                if (cleanup !is error) cleanup.next = error;
                                error = cleanup;
                            }
                        }
                        finally evaluatorContext.unwindingException = previousUnwinding;
                    }
                    if(pending.rescue !is null&&cast(ExecutionLimitException)error is null){
                        // catch本体の開始も次の実行フレームへ戻し、そこでの例外を
                        // 外側のtryで捕捉できるようにします。
                        auto rescue=pending.rescue;auto caughtError=error;
                        coPush(state,(){rescue(caughtError);});caught=true;break;
                    }
                }
                if(!caught){state.failed=true;state.failure=error;state.errorMessage=error.msg;state.dead=true;break;}
            }
        }
        if(!state.hasFrames())state.dead=true;
        if(state.dead)state.releaseExecution();
        if(state.failed)return Value.from([Value.from(false),Value.from(state.errorMessage)]);
        return Value.from([Value.from(true)]~(state.dead?state.returnValues:state.yieldedValues));
    }
    private Value coroutineStatus(Value handle){
        auto state=requireCoroutineState(handle);
        // 既存の公開status文字列とresumeの成功boolを保持します。
        return Value.from(state.dead?"dead":state.running?"running":"suspended");
    }
    private Value currentCoroutineHandle(){
        if(activeCoroutine is null)return Value.nullValue();
        foreach(id,state;coroutines)if(state is activeCoroutine)return coroutineHandle(id);
        return Value.nullValue();
    }
    private Value yieldFromScript(Value[] values){
        enforce(evaluatorContext.finallyDepth == 0, "Cannot yield during finally cleanup");
        enforce(activeCoroutine !is null,"yield can only be used inside a running coroutine");
        // 同期DコールバックのDスタックを暗黙に中断・再実行してはいけません。
        enforce(false,"Cannot yield across a synchronous native callback boundary");
        assert(0);
    }
    private void installCoroutineLibrary()
    {
        Value[string] library;
        library["create"] = Value.fromFunction(new NativeCallable("coroutine.create", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.create(callback) expects one argument");
            return createCoroutine(cast(Value) args[0]);
        }));
        library["resume"] = Value.fromFunction(new NativeCallable("coroutine.resume", (scope const(Value)[] args) {
            enforce(args.length >= 1, "coroutine.resume(co, ...) expects at least one argument");
            Value[] resumeArgs;
            foreach (arg; args[1 .. $]) resumeArgs ~= cast(Value) arg;
            return resumeCoroutine(cast(Value) args[0], resumeArgs);
        }));
        library["status"] = Value.fromFunction(new NativeCallable("coroutine.status", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.status(co) expects one argument");
            return coroutineStatus(cast(Value) args[0]);
        }));
        library["running"] = Value.fromFunction(new NativeCallable("coroutine.running", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.running() takes no arguments");
            return currentCoroutineHandle();
        }));
        library["isyieldable"] = Value.fromFunction(new NativeCallable("coroutine.isyieldable", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.isyieldable() takes no arguments");
            // 同期Dからの再入では中断できません。直接のDua呼出しはcoInvokeが扱います。
            return Value.from(false);
        }));
        coroutineYieldable=library["isyieldable"].functionValue;
        library["wrap"] = Value.fromFunction(new NativeCallable("coroutine.wrap", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.wrap(callback) expects one argument");
            auto handle = createCoroutine(cast(Value) args[0]);
            return Value.fromFunction(new NativeCallable("coroutine.wrapped", (scope const(Value)[] callArgs) {
                Value[] resumeArgs;
                foreach (arg; callArgs) resumeArgs ~= cast(Value) arg;
                auto resumed = resumeCoroutine(handle, resumeArgs);
                enforce(resumed.kind == ValueKind.array && resumed.arrayValue.length >= 1,
                    "coroutine.wrap resume failed");
                if (!resumed.arrayValue[0].truthy())
                {
                    // wrapは失敗を再送出するため、呼出元で元の位置を置き換えません。
                    auto failure = requireCoroutineState(handle).failure;
                    if (failure !is null) throw failure;
                    enforce(false, resumed.arrayValue.length > 1
                        ? resumed.arrayValue[1].toHostString() : "coroutine.wrap failure");
                }
                return resumed.arrayValue.length > 1 ? resumed.arrayValue[1] : Value.nullValue();
            }));
        }));
        globals.define("coroutine", Value.from(library));
    }

}
