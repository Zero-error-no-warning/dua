module dua.coroutineExecution;

import dua.ast;
import dua.value;
import dua.evaluator;
import dua.execution;
import dua.coroutine;
import dua.scope_planner;
import std.exception : enforce;
import std.format : format;

// 続きはこの明示的なフレーム列だけに保持します。advanceから次のフレームを
// 登録して戻るため、Dの呼出しスタックを停止したまま所有しません。
package struct CoroutineFrame {
    void delegate() advance;
    void delegate() unwind;
    void delegate(Exception) rescue;
    AstNode node;
    string role;
}

package mixin template StacklessExecution() {
    private alias CoValue = void delegate(Value);
    private alias CoResult = void delegate(ExecutionResult);

    private void coPush(CoroutineState task, void delegate() action,
        void delegate() unwind=null, void delegate(Exception) rescue=null,
        AstNode node=null,string role="") {
        task.push(CoroutineFrame(action,unwind,rescue,node is null?task.node:node,role.length?role:task.role));
    }
    private void coValue(CoroutineState task,CoValue done,Value value) {
        coPush(task,(){done(value);});
    }
    private void coResult(CoroutineState task,CoResult done,ExecutionResult result) {
        coPush(task,(){done(result);});
    }
    private void coScope(CoroutineState task,void delegate() finish) {
        coPush(task,finish,finish);
    }
    private void coNative(CoroutineState task,void delegate() action) {
        ++task.nativeDepth;
        scope(exit)--task.nativeDepth;
        action();
    }
    private void coStatements(CoroutineState task,Statement[] body,Environment env,
        CoResult done,size_t index=0,ExecutionResult previous=ExecutionResult.init) {
        coPush(task,(){
            if(index==body.length){coResult(task,done,previous);return;}
            coStatement(task,body[index],env,(ExecutionResult result){
                if(result.returned || result.broke || result.continued)coResult(task,done,result);
                else coStatements(task,body,env,done,index+1,result);
            });
        });
    }
    private void coList(CoroutineState task,Expression[] expressions,Environment env,
        void delegate(Value[]) done,bool expand=false,size_t index=0,Value[] values=null) {
        coPush(task,(){
            if(index==expressions.length){
                if(expand&&values.length==1&&values[0].kind==ValueKind.array)values=values[0].arrayValue.dup;
                done(values);return;
            }
            coEvaluate(task,expressions[index],env,(Value value){
                coList(task,expressions,env,done,expand,index+1,values~value);
            });
        });
    }
    private void coStatement(CoroutineState task,Statement stmt,Environment env,CoResult done) {
        coPush(task,(){
            if(stmt.kind!=Statement.Kind.functionDecl && stmt.kind!=Statement.Kind.alias_
                && stmt.kind!=Statement.Kind.tableDecl && stmt.kind!=Statement.Kind.structDecl
                && stmt.kind!=Statement.Kind.import_ && stmt.kind!=Statement.Kind.export_)consumeStep();
            enforce(!stmt.isInstance || env.initializingModule,
                "instance is only allowed in a source module's top-level declarations");
            auto declarations=env.sharedDeclarations !is null&&!stmt.isInstance?env.sharedDeclarations:env;
            final switch(stmt.kind) {
                case Statement.Kind.variableDecl:
                    coList(task,stmt.expressions,env,(Value[] values){
                        ExecutionResult result;
                        foreach(i,name;stmt.names){
                            auto value=i<values.length?values[i]:Value.nullValue();
                            auto type=stmt.declaredType;
                            coNative(task,(){
                                if(type.length&&type!="auto"){
                                    value=prepareContainerValue(value,type);
                                    enforce(valueMatchesType(value,type),typeMismatchMessage(type,
                                        format("Variable '%s' expected %s but got %s",name,type,value.kind)));
                                }
                                string element,key;
                                if(splitContainerType(resolveContainerType(type),element,key)
                                    ||hasLiteralConstraint(type)||hasNonNullConstraint(type)||hasContainerConstraint(type) || hasFloatingPromotion(type))
                                    declarations.define(name,value,containerValidator(type));
                                else declarations.define(name,value);
                                declarations.declareType(name,type);
                                if(stmt.isExported)exportSymbol(name,value);
                            });
                            result.lastValue=value;
                        }
                        coResult(task,done,result);
                    },stmt.names.length>1);break;
                case Statement.Kind.expression:
                    coEvaluate(task,stmt.expression,env,(Value value){coResult(task,done,ExecutionResult(value));});break;
                case Statement.Kind.return_:
                    coList(task,stmt.expressions,env,(Value[] values){
                        auto value=values.length==0?Value.nullValue():values.length==1?values[0]:Value.fromOwnedArray(values);
                        coResult(task,done,ExecutionResult(value,true));
                    });break;
                case Statement.Kind.yield_:
                    coList(task,stmt.expressions,env,(Value[] values){
                        task.yieldedValues=values.length?values:[Value.nullValue()];
                        task.suspended=true;
                        coPush(task,(){coResult(task,done,ExecutionResult(task.pendingArgs.length?task.pendingArgs[0]:Value.nullValue()));});
                    });break;
                case Statement.Kind.block:
                    coStatements(task,stmt.body,new Environment(env,layoutFor(stmt)),done);break;
                case Statement.Kind.if_:
                    coEvaluate(task,stmt.condition,env,(Value test){
                        if(test.truthy())coStatement(task,stmt.body[0],env,done);
                        else if(stmt.elseBranch !is null)coStatement(task,stmt.elseBranch,env,done);
                        else coResult(task,done,ExecutionResult.init);
                    });break;
                case Statement.Kind.while_:
                    coLoop(task,stmt,env,done);break;
                case Statement.Kind.for_:
                    auto loopEnv=new Environment(env,layoutFor(stmt));
                    if(stmt.init !is null)coStatement(task,stmt.init,loopEnv,(ExecutionResult init){
                        if(init.returned)coResult(task,done,init);else coLoop(task,stmt,loopEnv,done);
                    });else coLoop(task,stmt,loopEnv,done);
                    break;
                case Statement.Kind.foreach_:
                    coEvaluate(task,stmt.iterable,env,(Value collection){
                        enforce(!stmt.reverseIteration || stmt.rangeEnd !is null || collection.kind==ValueKind.array,
                            "foreach_reverse expects an array or an integer range");
                        if(stmt.rangeEnd !is null)coEvaluate(task,stmt.rangeEnd,env,(Value end){
                            enforce(collection.kind==ValueKind.integer&&end.kind==ValueKind.integer,"Range foreach bounds must be integers");
                            coRange(task,stmt,env,collection.integerValue,end.integerValue,done);
                        });else{
                            Value[] keys,values;
                            if(collection.kind==ValueKind.array){
                                foreach(i,value;collection.arrayValue){keys~=Value.from(cast(long)i);values~=value;}
                            }else if(collection.kind==ValueKind.associativeArray){
                                foreach(entry;collection.associativeEntries){keys~=entry.key.keyCopy();values~=cast(Value)entry.value;}
                            }else if(collection.kind==ValueKind.table){
                                foreach(key,value;collection.tableValue){keys~=tableKeyToScriptValue(key);values~=value;}
                            }else enforce(false,"foreach expects array, associative array, or table");
                            coEach(task,stmt,env,collection,keys,values,0,done);
                        }
                    });break;
                case Statement.Kind.switch_:
                    coEvaluate(task,stmt.expression,env,(Value value){coSwitch(task,stmt,env,value,0,done);});break;
                case Statement.Kind.break_:
                    coResult(task,done,ExecutionResult(Value.nullValue(),false,true));break;
                case Statement.Kind.continue_:
                    coResult(task,done,ExecutionResult(Value.nullValue(),false,false,true));break;
                case Statement.Kind.try_:
                    ExecutionResult result;
                    bool hasFinal = stmt.finallyBranch !is null;
                    if (hasFinal)
                    {
                        bool cleaned;
                        void cleanup()
                        {
                            if (cleaned) return;
                            cleaned = true;
                            coNative(task, () { executeFinally(stmt.finallyBranch, env, evaluatorContext.unwindingException); });
                        }
                        coPush(task, () { cleanup(); coResult(task, done, result); }, &cleanup);
                    }
                    CoResult caughtResult = hasFinal ? (ExecutionResult value) { result = value; } : done;
                    void delegate(Exception) rescue;
                    if (stmt.elseBranch !is null) rescue = (Exception error) {
                        Value original=Value.nullValue();string kind="RuntimeError";
                        if(auto thrown=cast(ScriptThrownException)error){original=thrown.thrownValue;kind="ScriptError";}
                        Value[] trace;foreach(name;evaluatorContext.lastErrorStack)trace~=Value.from(name);
                        auto info=Value.from(["kind":Value.from(kind),"message":Value.from(error.msg),"value":original,"stack":Value.from(trace)]);
                        auto scope_=new Environment(env,catchLayoutFor(stmt));scope_.define(stmt.name,info);
                        coStatements(task,stmt.elseBranch.body,scope_,caughtResult);
                    };
                    coPush(task, () { if (!hasFinal) coResult(task, done, result); }, null, rescue);
                    coStatements(task,stmt.body,new Environment(env,layoutFor(stmt)),(ExecutionResult value){result=value;});
                    break;

                case Statement.Kind.assign:
                    if(stmt.assignmentOperator.length){
                        coTarget(task,stmt.target,env,(Expression target){
                            coEvaluate(task,target,env,(Value left){
                                coEvaluate(task,stmt.expression,env,(Value right){
                                    coBinary(task,stmt.assignmentOperator,left,right,(Value value){
                                        coAssign(task,target,value,env,false,(){coResult(task,done,ExecutionResult(value));});
                                    });
                                });
                            });
                        },true);
                    }else coList(task,stmt.expressions,env,(Value[] values){coAssignList(task,stmt.targets,values,env,0,done);},stmt.targets.length>1);
                    break;
                case Statement.Kind.functionDecl:
                case Statement.Kind.alias_:
                case Statement.Kind.tableDecl:
                case Statement.Kind.structDecl:
                case Statement.Kind.import_:
                case Statement.Kind.export_:
                    void runDeclaration(Statement declaration){
                        ExecutionResult value;
                        coNative(task,(){value=executeStatement(declaration,env);});
                        coResult(task,done,value);
                    }
                    if(stmt.metatableReference !is null){
                        // ASTは他の実行と共有するので書き換えず、解決済みmetaだけを渡します。
                        coEvaluate(task,stmt.metatableReference,env,(Value meta){
                            auto declaration=new Statement(stmt.kind);
                            declaration.tupleof=stmt.tupleof;
                            declaration.line=stmt.line;declaration.column=stmt.column;
                            declaration.metatableReference=new LiteralExpression(meta);
                            runDeclaration(declaration);
                        });
                    }else runDeclaration(stmt);
                    break;
            }
        },null,null,stmt,"statement");
    }
    private void coLoop(CoroutineState task,Statement stmt,Environment env,CoResult done) {
        coPush(task,(){
            void condition(Value value){
                if(!value.truthy()){coResult(task,done,ExecutionResult.init);return;}
                coStatement(task,stmt.body[0],env,(ExecutionResult result){
                    if(result.returned){coResult(task,done,result);return;}
                    if(result.broke){result.broke=false;coResult(task,done,result);return;}
                    if(stmt.kind==Statement.Kind.for_&&stmt.incrementStatement !is null){
                        coStatement(task,stmt.incrementStatement,env,(ExecutionResult increment){
                            if(increment.returned)coResult(task,done,increment);else coLoop(task,stmt,env,done);
                        });
                    }else coLoop(task,stmt,env,done);
                });
            }
            if(stmt.condition is null)condition(Value.from(true));else coEvaluate(task,stmt.condition,env,&condition);
        });
    }
    private void coRange(CoroutineState task,Statement stmt,Environment env,long index,long end,CoResult done) {
        coPush(task,(){
            if(index>=end){coResult(task,done,ExecutionResult.init);return;}
            auto current=stmt.reverseIteration?end-1:index;
            auto scope_=new Environment(env,layoutFor(stmt));scope_.define(stmt.iteratorName,Value.from(current));
            coStatement(task,stmt.body[0],scope_,(ExecutionResult result){
                if(result.returned)coResult(task,done,result);
                else if(result.broke){result.broke=false;coResult(task,done,result);}
                else coRange(task,stmt,env,stmt.reverseIteration?index:index+1,stmt.reverseIteration?end-1:end,done);
            });
        });
    }
    private void coEach(CoroutineState task,Statement stmt,Environment env,Value collection,
        Value[] keys,Value[] values,size_t index,CoResult done) {
        coPush(task,(){
            if(index==values.length){coResult(task,done,ExecutionResult.init);return;}
            auto scope_=new Environment(env,layoutFor(stmt));
            auto position=stmt.reverseIteration?values.length-1-index:index;
            auto value=collection.kind==ValueKind.array?collection.arrayValue[position]:values[position];
            if(collection.kind==ValueKind.table){
                auto key=keys[index].toHostString();
                if(auto current=key in collection.tableValue)value=*current;
            }
            scope_.define(stmt.iteratorName,stmt.iteratorSecondName.length?keys[position]:value);
            if(stmt.iteratorSecondName.length)scope_.define(stmt.iteratorSecondName,value);
            coStatement(task,stmt.body[0],scope_,(ExecutionResult result){
                if(result.returned)coResult(task,done,result);
                else if(result.broke){result.broke=false;coResult(task,done,result);}
                else coEach(task,stmt,env,collection,keys,values,index+1,done);
            });
        });
    }
    private void coSwitch(CoroutineState task,Statement stmt,Environment env,Value value,size_t index,CoResult done) {
        coPush(task,(){
            if(index==stmt.switchCases.length){coResult(task,done,ExecutionResult.init);return;}
            auto branch=stmt.switchCases[index];
            void matched(bool yes){
                if(!yes){coSwitch(task,stmt,env,value,index+1,done);return;}
                coStatements(task,branch.body,new Environment(env,layoutFor(branch)),(ExecutionResult result){result.broke=false;coResult(task,done,result);});
            }
            if(branch.isDefault)matched(true);else coEvaluate(task,branch.pattern,env,(Value pattern){matched(valuesEqual(value,pattern));});
        });
    }
}
