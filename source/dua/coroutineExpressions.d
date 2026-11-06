module dua.coroutineExpressions;
import dua.ast;
import dua.value;
import dua.evaluator;
import dua.coroutine;
import dua.scope_planner;
import std.exception : enforce;
import std.format : format;

package mixin template StacklessExpressions() {
    private void coEvaluate(CoroutineState task,Expression expr,Environment env,CoValue done) {
        coPush(task,(){
            consumeStep();
            final switch(expr.kind){
                case Expression.Kind.literal:
                    coValue(task,done,(cast(LiteralExpression)expr).value);break;
                case Expression.Kind.variable:
                    auto variable=cast(VariableExpression)expr;
                    auto found=env.find(variable.name);
                    enforce(found !is null,"Undefined variable '"~variable.name~"'");
                    coForce(task,*found,done);break;
                case Expression.Kind.function_:
                    auto fn=cast(FunctionExpression)expr;
                    coValue(task,done,Value.fromFunction(new ScriptCallable("anonymous",this,env,
                        fn.parameters,fn.variadic,fn.body,fn.parameterTypes,fn.returnType,layoutFor(fn),
                        fn.line,fn.column,fn.parameterDefaults,fn.parameterLazy,fn.parameterRef)));break;
                case Expression.Kind.with_:
                    auto with_=cast(WithExpression)expr;
                    coEvaluate(task,with_.target,env,(Value value){
                        enforce(value.isFieldAggregate,"with target must be a table, struct or reflected object");
                        auto scope_=new Environment(env);scope_.define(with_.bindingName,value);
                        coEvaluate(task,with_.body,scope_,done);
                    });break;
                case Expression.Kind.cast_:
                    auto cast_=cast(CastExpression)expr;
                    coEvaluate(task,cast_.operand,env,(Value value){
                        coNative(task,(){value=castValue(value,cast_.targetType,cast_.checkedConversion);});coValue(task,done,value);
                    });break;
                case Expression.Kind.unary:
                    auto unary=cast(UnaryExpression)expr;
                    if(unary.operatorSymbol=="$"){
                        enforce(evaluatorContext.indexLengthStack.length>0,"$ is only available inside index expressions");
                        coValue(task,done,Value.from(evaluatorContext.indexLengthStack.top()));break;
                    }
                    coEvaluate(task,unary.operand,env,(Value operand){
                        Value method;
                        auto name=unary.operatorSymbol=="-"?"opUnary-":unary.operatorSymbol=="!"?"opUnary!":"opUnary"~unary.operatorSymbol;
                        if(operand.isFieldAggregate&&lookupMetamethod(operand,name,method))coInvoke(task,method,[operand],done);
                        else if(unary.operatorSymbol=="-")coValue(task,done,operand.kind==ValueKind.integer?Value.from(-operand.integerValue):Value.from(-operand.toFloat()));
                        else if(unary.operatorSymbol=="!")coValue(task,done,Value.from(!operand.truthy()));
                        else if(unary.operatorSymbol=="new"){
                            Value value;coNative(task,(){value=instantiateModuleValue(operand);});coValue(task,done,value);
                        }else enforce(false,"Unsupported unary operator '"~unary.operatorSymbol~"'");
                    });break;
                case Expression.Kind.binary:
                    auto binary=cast(BinaryExpression)expr;
                    coEvaluate(task,binary.left,env,(Value left){
                        if(binary.operatorSymbol=="is"){
                            coValue(task,done,Value.from(valueIsType(left,(cast(VariableExpression)binary.right).name)));return;
                        }
                        if(binary.operatorSymbol=="??"){
                            if(left.isNullReference)coEvaluate(task,binary.right,env,done);
                            else coValue(task,done,left);
                            return;
                        }
                        if(binary.operatorSymbol=="&&"&&!left.truthy()){coValue(task,done,Value.from(false));return;}
                        if(binary.operatorSymbol=="||"&&left.truthy()){coValue(task,done,Value.from(true));return;}
                        coEvaluate(task,binary.right,env,(Value right){
                            if(binary.operatorSymbol=="&&"||binary.operatorSymbol=="||")coValue(task,done,Value.from(right.truthy()));
                            else coBinary(task,binary.operatorSymbol,left,right,done);
                        });
                    });break;
                case Expression.Kind.ternary:
                    auto choice=cast(TernaryExpression)expr;
                    coEvaluate(task,choice.condition,env,(Value test){coEvaluate(task,test.truthy()?choice.whenTrue:choice.whenFalse,env,done);});break;
                case Expression.Kind.call:
                    auto call=cast(CallExpression)expr;coCall(task,call.callee,call.arguments,env,callSite(call),done,call.argumentNames);break;
                case Expression.Kind.array:
                    coArray(task,cast(ArrayExpression)expr,env,0,null,done);break;
                case Expression.Kind.associativeArray:
                    coAssociative(task,cast(AssociativeArrayExpression)expr,env,0,Value.associativeArray(),done);break;
                case Expression.Kind.table:
                    coTable(task,cast(TableExpression)expr,env,0,null,done);break;
                case Expression.Kind.get:
                    auto get=cast(GetExpression)expr;
                    coEvaluate(task,get.target,env,(Value receiver){coGet(task,receiver,get,env,done);});break;
                case Expression.Kind.index:
                    auto index=cast(IndexExpression)expr;
                    coEvaluate(task,index.target,env,(Value receiver){
                        enforce(receiver.kind!=ValueKind.null_,"Cannot index untyped null");
                        auto length=canMeasureLength(receiver);
                        if(length)evaluatorContext.indexLengthStack.push(measuredLength(receiver));
                        Value result;
                        void restore(){if(length)evaluatorContext.indexLengthStack.pop();}
                        coPush(task,(){restore();coValue(task,done,result);},&restore);
                        if(index.isSlice){
                            coEvaluate(task,index.sliceStart,env,(Value start){coEvaluate(task,index.sliceEnd,env,(Value end){
                                enforce(receiver.kind==ValueKind.array,"Slicing currently supports arrays only");
                                auto lo=start.toInt(),hi=end.toInt();
                                enforce(lo>=0&&hi>=lo,"Invalid slice range");enforce(hi<=receiver.arrayValue.length,"Slice end out of range");
                                result=receiver.slicedArrayHandle(cast(size_t)lo,cast(size_t)hi);
                            });});
                        }else coList(task,index.indices,env,(Value[] indices){coIndex(task,receiver,indices,callSite(expr),(Value value){result=value;});});
                    });break;
            }
        },null,null,expr,"expression");
    }
    private void coArray(CoroutineState task,ArrayExpression expr,Environment env,size_t index,Value[] values,CoValue done){
        if(index==expr.elements.length){coValue(task,done,Value.fromOwnedArray(values));return;}
        coEvaluate(task,expr.elements[index],env,(Value value){
            if(index<expr.elementSpreads.length&&expr.elementSpreads[index]){
                enforce(value.kind==ValueKind.array,"Array spread requires an array value");values~=value.arrayValue;
            }else values~=value;
            coArray(task,expr,env,index+1,values,done);
        });
    }
    private void coBinary(CoroutineState task,string op,Value left,Value right,CoValue done) {
        Value method;
        if(left.isFieldAggregate&&lookupMetamethod(left,binaryOperatorSlot(op,false),method)){coInvoke(task,method,[left,right],done);return;}
        if(right.isFieldAggregate&&lookupMetamethod(right,binaryOperatorSlot(op,true),method)){coInvoke(task,method,[right,left],done);return;}
        if(op=="=="||op=="!="){
            void equality(Value value){coValue(task,done,Value.from(op=="=="?value.truthy():!value.truthy()));}
            if(left.isFieldAggregate&&lookupMetamethod(left,"__eq",method)){coInvoke(task,method,[left,right],&equality);return;}
            if(right.isFieldAggregate&&lookupMetamethod(right,"__eq",method)){coInvoke(task,method,[right,left],&equality);return;}
        }
        if(op=="~"&&left.kind!=ValueKind.array){
            coString(task,left,(Value a){coString(task,right,(Value b){coValue(task,done,Value.from(a.toHostString()~b.toHostString()));});});return;
        }
        Value result;coNative(task,(){result=evaluateBinary(op,left,right);});coValue(task,done,result);
    }
    private void coString(CoroutineState task,Value value,CoValue done){
        Value method;
        if(value.isFieldAggregate&&lookupMetamethod(value,"__tostring",method)){coInvoke(task,method,[value],done);return;}
        coValue(task,done,Value.from(value.toHostString()));
    }
    private void coAssociative(CoroutineState task,AssociativeArrayExpression expr,Environment env,
        size_t index,Value result,CoValue done) {
        if(index==expr.keys.length){coValue(task,done,result);return;}
        coEvaluate(task,expr.keys[index],env,(Value key){coEvaluate(task,expr.values[index],env,(Value value){
            result.associativeSet(key,value);coAssociative(task,expr,env,index+1,result,done);
        });});
    }
    private void coTable(CoroutineState task,TableExpression expr,Environment env,size_t index,
        Value[string] entries,CoValue done) {
        coPush(task,(){
            if(index==expr.entries.length){
                auto value=Value.from(entries);
                if(expr.targetType.length)coNative(task,(){value=constructNamedTable(expr.targetType,value);});
                coValue(task,done,value);return;
            }
            auto entry=expr.entries[index];
            if(entry.isSpread){
                coEvaluate(task,entry.value,env,(Value value){
                    enforce(value.kind==ValueKind.table,"Table spread requires a table value");
                    foreach(key,item;value.tableValue){
                        if(key=="__meta")continue;
                        enforce(!expr.targetType.length||(key in entries)is null,"Duplicate initializer field '"~key~"'");entries[key]=item;
                    }
                    coTable(task,expr,env,index+1,entries,done);
                });return;
            }
            void keyReady(string key){
                enforce(!expr.targetType.length||(key in entries)is null,"Duplicate initializer field '"~key~"'");
                coEvaluate(task,entry.value,env,(Value value){entries[key]=value;coTable(task,expr,env,index+1,entries,done);});
            }
            if(entry.keyExpression !is null&&!entry.isArrayEntry)coEvaluate(task,entry.keyExpression,env,(Value key){keyReady(key.toHostString());});
            else keyReady(entry.key);
        });
    }
    private void coGet(CoroutineState task,Value receiver,GetExpression get,Environment env,CoValue done) {
        if(get.nullConditional && receiver.isNullReference){coValue(task,done,Value.nullValue());return;}
        enforce(receiver.kind!=ValueKind.null_,"Cannot access member '"~get.memberName~"' on null");
        if((receiver.kind==ValueKind.array||receiver.kind==ValueKind.string_)&&get.memberName=="length"){coValue(task,done,Value.from(measuredLength(receiver)));return;}
        if(receiver.kind==ValueKind.associativeArray&&(get.memberName=="keys"||get.memberName=="values"||get.memberName=="length")){
            coValue(task,done,associativeProperty(receiver,get.memberName));return;
        }
        if(receiver.isFieldAggregate){
            Value getter;
            if(receiver.lookupPropertyGetter(get.memberName,getter)){
                coInvokeThis(task,getter,[],receiver,(Value value){
                    auto original=receiver.findMember(get.memberName);
                    if(!receiver.isClassReference&&(original is null||original.kind!=ValueKind.function_))receiver.refreshMember(get.memberName,value);
                    coValue(task,done,value);
                },callSite(get));return;
            }
            if(auto found=receiver.findMember(get.memberName)){
                if(receiver.moduleOwner is null&&found.kind==ValueKind.function_&&found.functionValue.acceptsArity(0))
                    coInvokeThis(task,*found,[],receiver,done,callSite(get));
                else coValue(task,done,found.withReceiver(receiver));
                return;
            }
            Value method;
            if(lookupMetamethod(receiver,"__index",method)&&method.kind==ValueKind.function_){coInvoke(task,method,[receiver,Value.from(get.memberName)],done);return;}
            Value resolved;bool found;
            coNative(task,(){found=resolveTableIndex(receiver,get.memberName,resolved);});
            if(found){coValue(task,done,resolved);return;}
        }
        if(!get.withMember)if(auto ufcs=resolveUfcs(get.memberName,env)){
            auto fn=ufcs.functionValue;
            auto known=fn.expectedArity()!=size_t.max||fn.minimumArity()!=0||fn.maximumArity()!=size_t.max
                ||cast(ScriptCallable)fn !is null||cast(ReflectedCallable)fn !is null||cast(OverloadedReflectedCallable)fn !is null;
            if(known&&fn.acceptsArity(1)){coInvoke(task,*ufcs,[receiver],done,callSite(get));return;}
        }
        if(receiver.kind==ValueKind.associativeArray){coValue(task,done,associativeProperty(receiver,get.memberName));return;}
        enforce(receiver.isFieldAggregate,"Property access currently supports tables/reflected structs/classes or callable UFCS");
        enforce(false,"Unknown property '"~get.memberName~"'");
    }
    private void coIndex(CoroutineState task,Value receiver,Value[] indices,CallSite caller,CoValue done){
        if(receiver.isFieldAggregate){
            if(auto method=receiver.findMember("opIndex"))if(method.kind==ValueKind.function_){coInvokeThis(task,*method,indices,receiver,done,caller);return;}
            enforce(indices.length==1,"Indexing requires a single index unless opIndex is defined");
            auto key=indices[0].toHostString();
            Value getter;
            if(receiver.isClassReference&&receiver.lookupPropertyGetter(key,getter)){coInvokeThis(task,getter,[],receiver,done);return;}
            if(auto existing=receiver.findMember(key)){coValue(task,done,existing.withReceiver(receiver));return;}
            Value method;
            if(indices.length==1&&lookupMetamethod(receiver,"__index",method)&&method.kind==ValueKind.function_){
                coInvoke(task,method,[receiver,Value.from(key)],done,caller);return;
            }
        }
        Value value;coNative(task,(){value=readIndex(receiver,indices,caller);});coValue(task,done,value);
    }
    private void coTarget(CoroutineState task,Expression target,Environment env,void delegate(Expression) done,bool compound=false){
        coPush(task,(){
            if(target.kind==Expression.Kind.variable){done(target);return;}
            if(auto get=cast(GetExpression)target){
                void freeze(Expression writeback, Value receiver){
                    auto frozen=new GetExpression(new LiteralExpression(receiver),get.memberName);
                    frozen.line=target.line;frozen.column=target.column;frozen.arrayLengthTarget=writeback;
                    done(frozen);
                }
                if(get.memberName=="length"&&isAssignmentLocation(get.target))
                    coTarget(task,get.target,env,(Expression writeback){
                        coEvaluate(task,writeback,env,(Value receiver){freeze(writeback,receiver);});
                    });
                else coEvaluate(task,get.target,env,(Value receiver){freeze(get.arrayLengthTarget,receiver);});
                return;
            }
            if(auto indexed=cast(IndexExpression)target){
                if(compound){
                    enforce(!indexed.isSlice,"Slice cannot be an assignment target");enforce(indexed.indices.length==1,"Index assignment requires a single index");
                }
                coEvaluate(task,indexed.target,env,(Value receiver){
                    if(!compound){
                        enforce(receiver.kind!=ValueKind.null_,"Cannot index untyped null");
                        enforce(!indexed.isSlice,"Slice cannot be an assignment target");enforce(indexed.indices.length==1,"Index assignment requires a single index");
                    }
                    enforce(receiver.kind!=ValueKind.string_,"String elements are immutable");
                    if(compound&&receiver.isNativeAggregate)if(auto setter=receiver.findMember("opIndexAssign"))
                        enforce(setter.kind!=ValueKind.function_,"Native indexed compound assignment is not supported");
                    bool length=canMeasureLength(receiver);
                    if(length)evaluatorContext.indexLengthStack.push(measuredLength(receiver));
                    Expression frozen;
                    void restore(){if(length)evaluatorContext.indexLengthStack.pop();}
                    coPush(task,(){restore();done(frozen);},&restore);
                    coEvaluate(task,indexed.index,env,(Value index){
                        frozen=new IndexExpression(new LiteralExpression(receiver),new LiteralExpression(index));frozen.line=target.line;frozen.column=target.column;
                    });
                });return;
            }
            enforce(false,"Invalid assignment target");
        });
    }
    private void coAssignList(CoroutineState task,Expression[] targets,Value[] values,Environment env,size_t index,CoResult done){
        if(index==targets.length){coResult(task,done,ExecutionResult(index&&index<=values.length?values[index-1]:Value.nullValue()));return;}
        auto value=index<values.length?values[index]:Value.nullValue();
        coTarget(task,targets[index],env,(Expression target){coAssign(task,target,value,env,true,(){coAssignList(task,targets,values,env,index+1,done);});});
    }
    private void coAssign(CoroutineState task,Expression target,Value value,Environment env,bool simple,void delegate() done){
        coPush(task,(){
            if(auto get=cast(GetExpression)target){
                auto receiver=(cast(LiteralExpression)get.target).value;
                enforce(receiver.kind!=ValueKind.null_,"Cannot assign member '"~get.memberName~"' on null");
                if(receiver.kind==ValueKind.array&&get.memberName=="length"){
                    enforce(get.arrayLengthTarget !is null,"Array length requires an assignable array");
                    Value resized;coNative(task,(){resized=resizeScriptArray(receiver,value);});
                    coAssign(task,get.arrayLengthTarget,resized,env,true,done);return;
                }
                enforce(receiver.isFieldAggregate,"Property assignment currently supports tables/reflected structs/classes");
                coNative(task,(){value=receiver.validateFieldAssignment(get.memberName,value);});
                if(auto property=receiver.findMember(get.memberName))if(property.kind==ValueKind.function_&&property.functionValue.acceptsArity(1)){
                    coInvokeThis(task,*property,[value],receiver,(Value ignored){coPush(task,done);});return;
                }
                Value setter;
                if(receiver.lookupPropertySetter(get.memberName,setter)){coInvoke(task,setter,[value],(Value ignored){coPush(task,done);});return;}
                coNewIndex(task,receiver,get.memberName,value,done);return;
            }else if(auto index=cast(IndexExpression)target){
                auto receiver=(cast(LiteralExpression)index.target).value;
                auto key=(cast(LiteralExpression)index.index).value;
                if(receiver.isNativeAggregate)if(auto setter=receiver.findMember("opIndexAssign"))if(setter.kind==ValueKind.function_){
                    enforce(simple,"Native indexed compound assignment is not supported");
                    coInvokeThis(task,*setter,[value,key],receiver,(Value ignored){coPush(task,done);},callSite(target));return;
                }
                if(receiver.isFieldAggregate){
                    auto name=key.toHostString();coNative(task,(){value=receiver.validateFieldAssignment(name,value);});
                    coNewIndex(task,receiver,name,value,done);return;
                }
            }
            coNative(task,(){assignTarget(target,value,env,simple);});coPush(task,done);
        });
    }
    private void coNewIndex(CoroutineState task,Value receiver,string key,Value value,void delegate() done){
        Value method;
        if(lookupMetamethod(receiver,"__newindex",method)&&method.kind==ValueKind.function_){
            coInvoke(task,method,[receiver,Value.from(key),value],(Value ignored){coPush(task,done);});return;
        }
        coNative(task,(){if(!applyTableNewIndex(receiver,key,value))receiver.tableValue[key]=value.valueCopy();});
        coPush(task,done);
    }
}
