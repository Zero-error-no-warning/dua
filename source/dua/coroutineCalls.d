module dua.coroutineCalls;
import dua.ast;
import dua.value;
import dua.evaluator;
import dua.execution;
import dua.coroutine;
import dua.coroutineInterop;
import std.exception : enforce;
import std.format : format;

package mixin template StacklessCalls() {
    private void coForce(CoroutineState task,Value value,CoValue done){
        coPush(task,(){
            if(value.kind==ValueKind.function_){
                if(auto checked=cast(CheckedLazyArgument)value.functionValue){
                    coForce(task,checked.argument,(Value result){
                        coNative(task,(){result=prepareContainerValue(result,checked.type);enforce(valueMatchesType(result,checked.type),"Lazy argument expected "~checked.type);});
                        coValue(task,done,result);
                    });return;
                }
                if(auto expression=cast(ExpressionArgument)value.functionValue){
                    expression.closure.validateModuleLifetime();
                    auto scope_=enterModuleContext(expression.context);
                    auto source=evaluatorContext.sourceName,text=evaluatorContext.sourceText,module_=evaluatorContext.moduleName;
                    auto hasText=evaluatorContext.hasSourceText;
                    auto oldThis=evaluatorContext.thisContextStack;
                    evaluatorContext.sourceName=expression.sourceName;evaluatorContext.sourceText=expression.sourceText;
                    evaluatorContext.hasSourceText=expression.hasSourceText;evaluatorContext.moduleName=expression.moduleName;
                    evaluatorContext.thisContextStack=typeof(oldThis).init;
                    foreach(item;expression.thisStack)evaluatorContext.thisContextStack.push(item);
                    Value result;
                    void restore(){
                        evaluatorContext.sourceName=source;evaluatorContext.sourceText=text;evaluatorContext.moduleName=module_;
                        evaluatorContext.hasSourceText=hasText;evaluatorContext.thisContextStack=oldThis;leaveModuleContext(scope_);
                    }
                    coPush(task,(){restore();coValue(task,done,result);},&restore);
                    coEvaluate(task,expression.expression,expression.closure,(Value value){result=value;});return;
                }
                if(cast(DeferredArgument)value.functionValue !is null){
                    coNative(task,(){value=forceArgument(value);});
                }
            }
            coValue(task,done,value);
        });
    }
    private void coArguments(CoroutineState task,Value fn,Expression[] expressions,Environment env,
        void delegate(Value[]) done,size_t offset=0,size_t index=0,Value[] values=null,string[] names=null){
        coPush(task,(){
            if(names.length){coNamedArguments(task,fn,expressions,names,env,offset,done);return;}
            if(index==expressions.length){done(values);return;}
            auto callee=fn;auto actualOffset=offset;
            if(callee.isFieldAggregate){
                if(auto method=callee.findMember("opCall"))callee=*method;
                else{Value method;if(lookupMetamethod(callee,"__call",method)){callee=method;++actualOffset;}}
            }
            if(callee.kind==ValueKind.function_&&callee.functionValue.refParameter(index+actualOffset)){
                values~=referenceCallArgument(expressions[index],env);
                coArguments(task,fn,expressions,env,done,offset,index+1,values);
            }else if(callee.kind==ValueKind.function_&&callee.functionValue.lazyParameter(index+actualOffset)){
                values~=Value.fromFunction(new ExpressionArgument(this,env,expressions[index]));
                coArguments(task,fn,expressions,env,done,offset,index+1,values);
            }else coEvaluate(task,expressions[index],env,(Value value){coArguments(task,fn,expressions,env,done,offset,index+1,values~value);});
        });
    }
    private void coNamedArguments(CoroutineState task, Value fn, Expression[] expressions,
        string[] names, Environment env, size_t offset, void delegate(Value[]) done)
    {
        if (fn.isFieldAggregate)
        {
            if (auto method = fn.findMember("opCall")) fn = *method;
            else { Value method; if (lookupMetamethod(fn, "__call", method)) { fn = method; ++offset; } }
        }
        auto plan = namedArgumentPlan(fn, names, offset);
        auto values = new Value[plan.length];
        foreach (ref value; values) value = omittedArgumentValue();
        void next(size_t index)
        {
            coPush(task, () {
                if (index == expressions.length) { done(values); return; }
                auto position = plan.positions[index];
                if (fn.functionValue.refParameter(position + offset))
                {
                    values[position] = referenceCallArgument(expressions[index], env);
                    next(index + 1);
                }
                else if (fn.functionValue.lazyParameter(position + offset))
                {
                    values[position] = Value.fromFunction(new ExpressionArgument(this, env, expressions[index]));
                    next(index + 1);
                }
                else coEvaluate(task, expressions[index], env, (Value value) {
                    values[position] = value; next(index + 1);
                });
            });
        }
        next(0);
    }

    private void coCall(CoroutineState task,Expression callee,Expression[] expressions,Environment env,CallSite caller,CoValue done,string[] names=null){
        if(auto get=cast(GetExpression)callee){
            if(!get.nullConditional&&!get.withMember)if(auto ufcs=resolveUfcs(get.memberName,env))if(ufcs.functionValue.lazyParameter(0)){
                auto known=unevaluatedCallable(get.target,env);
                auto member=known.isFieldAggregate?known.findMember(get.memberName):null;
                if(member is null){
                    auto type=unevaluatedType(get.target,env);
                    import std.algorithm : canFind;
                    enforce(known.isFieldAggregate||["int","long","uint","ulong","float","double","bool","string","array"].canFind(type),
                        "Cannot resolve lazy UFCS receiver without evaluation; use an explicit function call");
                    auto fn=*ufcs;
                    Value[] args=[Value.fromFunction(new ExpressionArgument(this,env,get.target))];
                    coArguments(task,fn,expressions,env,(Value[] tail){coInvoke(task,fn,args~tail,done,caller);},1,0,null,names);return;
                }
            }
            coEvaluate(task,get.target,env,(Value receiver){
                if(get.nullConditional&&receiver.isNullReference){coValue(task,done,Value.nullValue());return;}
                Value fn;size_t offset;
                if(receiver.isFieldAggregate)if(auto method=receiver.findMember(get.memberName))fn=*method;
                if(fn.kind==ValueKind.null_&&!get.withMember)if(auto ufcs=resolveUfcs(get.memberName,env)){fn=*ufcs;offset=1;}
                coArguments(task,fn,expressions,env,(Value[] args){
                    enforce(receiver.kind!=ValueKind.null_,"Cannot call member '"~get.memberName~"' on null");
                    if(receiver.isFieldAggregate)if(auto method=receiver.findMember(get.memberName)){
                        if(method.isFieldAggregate)coInvokeCallable(task,*method,args,done,caller);
                        else{enforce(method.kind==ValueKind.function_,"Property '"~get.memberName~"' exists but is not callable");coInvokeThis(task,*method,args,receiver,done,caller);}
                        return;
                    }
                    // AA組込メソッドをUFCSより先に処理する既存順序を保ちます。
                    if(receiver.kind==ValueKind.associativeArray&&(get.memberName=="keys"||get.memberName=="values"||get.memberName=="length"
                        ||get.memberName=="contains"||get.memberName=="remove"||get.memberName=="get")){
                        Value value;coNative(task,(){value=callMethodOrUfcs(receiver,get.memberName,args,env,caller,!get.withMember);});coValue(task,done,value);return;
                    }
                    if(!get.withMember)if(auto ufcs=resolveUfcs(get.memberName,env)){coInvoke(task,*ufcs,[receiver]~args,done,caller);return;}
                    enforce(false,"No method or UFCS function named '"~get.memberName~"'");
                },offset,0,null,names);
            });return;
        }
        coEvaluate(task,callee,env,(Value fn){coArguments(task,fn,expressions,env,(Value[] args){coInvokeCallable(task,fn,args,done,caller);},0,0,null,names);});
    }
    private void coInvokeCallable(CoroutineState task,Value fn,Value[] args,CoValue done,CallSite caller=CallSite.init){
        if(fn.isFieldAggregate){
            if(auto method=fn.findMember("opCall"))if(method.kind==ValueKind.function_){coInvokeThis(task,*method,args,fn,done,caller);return;}
            Value method;if(lookupMetamethod(fn,"__call",method)){coInvoke(task,method,[fn]~args,done,caller);return;}
        }
        coInvoke(task,fn,args,done,caller);
    }
    private void coInvokeThis(CoroutineState task,Value fn,Value[] args,Value receiver,CoValue done,CallSite caller=CallSite.init){
        coPush(task,(){
            evaluatorContext.thisContextStack.push(receiver);Value result;
            void restore(){evaluatorContext.thisContextStack.pop();}
            coPush(task,(){restore();coValue(task,done,result);},&restore);
            coInvoke(task,fn.withReceiver(receiver),args,(Value value){result=value;},caller);
        });
    }
    private void coInvoke(CoroutineState task,Value fn,Value[] args,CoValue done,CallSite caller=CallSite.init){
        coPush(task,(){
            enforce(fn.kind==ValueKind.function_,"Only functions are callable");
            if(fn.functionValue is coroutineYieldable){
                enforce(args.length==0,"coroutine.isyieldable() takes no arguments");
                coValue(task,done,Value.from(task.nativeDepth==0));return;
            }
            if(auto wrapper=cast(CoroutineWrapper)fn.functionValue){
                auto target=wrapper.coroutineTarget();
                if(coResumableTarget(target)){
                    coInvoke(task,Value.fromFunction(target),args,(Value value){
                        coNative(task,(){value=wrapper.coroutineResult(value);});coValue(task,done,value);
                    },caller);return;
                }
            }
            if(auto wait=cast(CoroutineWait)fn.functionValue){
                bool delegate() poll;coNative(task,(){poll=wait.beginWait(args);});
                coWait(task,poll,done);return;
            }
            if(auto script=cast(ScriptCallable)fn.functionValue){
                if(script.engine is this){coPrepare(task,script,copyValues(args),0,(Value[] prepared){coScript(task,script,prepared,done);});return;}
            }
            Value result;
            coNative(task,(){result=invokeFunctionValue(fn,args,caller);});
            coValue(task,done,result);
        });
    }
    private bool coResumableTarget(CallableValue target){
        if(cast(ScriptCallable)target !is null||cast(CoroutineWait)target !is null)return true;
        if(auto wrapper=cast(CoroutineWrapper)target)return coResumableTarget(wrapper.coroutineTarget());
        return false;
    }
    private void coWait(CoroutineState task,bool delegate() poll,CoValue done){
        coPush(task,(){
            bool suspend;coNative(task,(){suspend=poll();});
            if(!suspend){coValue(task,done,Value.nullValue());return;}
            task.suspended=true;coWait(task,poll,done);
        });
    }
    private void coPrepare(CoroutineState task,ScriptCallable fn,Value[] args,size_t index,void delegate(Value[]) done){
        coPush(task,(){
            if(index==args.length){done(args);return;}
            if(fn.lazyParameter(index)||fn.refParameter(index))coPrepare(task,fn,args,index+1,done);
            else coForce(task,args[index],(Value value){args[index]=value;coPrepare(task,fn,args,index+1,done);});
        });
    }
    private void coScript(CoroutineState task,ScriptCallable fn,Value[] args,CoValue done){
        fn.closure.validateModuleLifetime();
        auto maxDepth=evaluatorContext.currentRunOptions.limits.maxCallDepth;
        enforce(maxDepth==0||evaluatorContext.callStack.length<maxDepth,new CallDepthLimitException(maxDepth));
        auto scope_=enterModuleContext(fn.moduleContext);
        auto source=evaluatorContext.sourceName,text=evaluatorContext.sourceText,module_=evaluatorContext.moduleName;
        auto hasText=evaluatorContext.hasSourceText;
        evaluatorContext.sourceName=fn.sourceName;evaluatorContext.sourceText=fn.sourceText;
        evaluatorContext.hasSourceText=fn.hasSourceText;evaluatorContext.moduleName=fn.moduleName;
        evaluatorContext.callStack.push(fn.debugName);
        Value result;
        void restore(){
            evaluatorContext.callStack.pop();evaluatorContext.sourceName=source;evaluatorContext.sourceText=text;
            evaluatorContext.hasSourceText=hasText;evaluatorContext.moduleName=module_;leaveModuleContext(scope_);
        }
        coPush(task,(){restore();coValue(task,done,result.valueCopy());},&restore);
        auto supplied=args.length;
        if(fn.parameterDefaults.length){
            enforce(args.length>=fn.requiredArguments&&(fn.variadic||args.length<=fn.parameters.length),
                format("Function '%s' expected %s to %s arguments but got %s",fn.debugName,fn.requiredArguments,
                    fn.variadic?"unlimited":format("%s",fn.parameters.length),args.length));
            auto fixed=fn.variadic?fn.parameters.length-1:fn.parameters.length;
            if(args.length<fixed){auto filled=new Value[fixed];filled[0..args.length]=args[];args=filled;}
        }else enforce(fn.variadic?args.length>=fn.requiredArguments:args.length==fn.parameters.length,
            format("Function '%s' expected %s arguments but got %s",fn.debugName,fn.parameters.length,args.length));
        auto env=new Environment(fn.closure,fn.scopeLayout);
        if(fn.parameterDefaults.length&&(fn.repeatedParameterNames||supplied<(fn.variadic?fn.parameters.length-1:fn.parameters.length)||hasOmittedArguments(args))){
            env.pendingBindingLabel="Parameter";foreach(name;fn.parameters)env.reserveDeclaration(name);
        }
        if(hasThisContext())env.define("this",currentThisContext());
        coParameters(task,fn,args,supplied,env,0,(){
            coStatements(task,fn.body,env,(ExecutionResult returned){
                result=returned.returned?returned.lastValue:Value.nullValue();
                if(fn.returnType.length)coNative(task,(){
                    result=prepareContainerValue(result,fn.returnType);
                    enforce(valueMatchesType(result,fn.returnType),typeMismatchMessage(fn.returnType,
                        format("Function '%s' expected return type %s but got %s",fn.debugName,fn.returnType,result.kind)));
                });
            });
        });
    }
    private void coParameters(CoroutineState task,ScriptCallable fn,Value[] args,size_t supplied,Environment env,size_t index,void delegate() done){
        coPush(task,(){
            if(index==fn.parameters.length){done();return;}
            auto name=fn.parameters[index];
            if(fn.refParameter(index)){
                enforce(index<supplied,"Missing required ref argument: "~name);
                bindReferenceParameter(env,name,args[index],fn.parameterTypes[index]);
                coParameters(task,fn,args,supplied,env,index+1,done);return;
            }
            if(fn.lazyParameter(index)){
                enforce(index<supplied&&!isOmittedArgument(args[index]),"Missing required lazy argument: "~name);
                env.define(name,Value.fromFunction(new CheckedLazyArgument(this,args[index],fn.parameterTypes[index])));
                env.declareType(name,fn.parameterTypes[index]);
                coParameters(task,fn,args,supplied,env,index+1,done);return;
            }
            if(fn.variadic&&index+1==fn.parameters.length){
                auto rest=Value.from(args[index..$].dup);
                coNative(task,(){
                    if(index<fn.parameterTypes.length&&(hasLiteralConstraint(fn.parameterTypes[index])||hasNonNullConstraint(fn.parameterTypes[index])||hasContainerConstraint(fn.parameterTypes[index]) || hasFloatingPromotion(fn.parameterTypes[index]))){
                        auto type=fn.parameterTypes[index]~"[]";rest=prepareContainerValue(rest,type);env.define(name,rest,containerValidator(type));
                    }else env.define(name,rest);
                });done();return;
            }
            void bindValue(Value value){
                coNative(task,(){
                    if(index<fn.parameterTypes.length){
                        auto type=fn.parameterTypes[index];value=prepareContainerValue(value,type);
                        enforce(valueMatchesType(value,type),typeMismatchMessage(type,format("Function '%s' argument '%s' expected %s but got %s",fn.debugName,name,type,value.kind)));
                        string element,key;
                        if(splitContainerType(resolveContainerType(type),element,key)||hasLiteralConstraint(type)||hasNonNullConstraint(type)||hasContainerConstraint(type) || hasFloatingPromotion(type))env.define(name,value,containerValidator(type));
                        else env.define(name,value);
                        env.declareType(name,type);
                    }else env.define(name,value);
                });
                coParameters(task,fn,args,supplied,env,index+1,done);
            }
            if(index>=supplied||isOmittedArgument(args[index])){
                enforce(index<fn.parameterDefaults.length&&fn.parameterDefaults[index] !is null,"Missing required argument: "~name);
                coEvaluate(task,fn.parameterDefaults[index],env,&bindValue);
            }else bindValue(args[index]);
        });
    }
}
