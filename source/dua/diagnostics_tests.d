module dua.diagnostics_tests;
version(unittest):
import dua;
import std;

unittest
{
    auto engine=new Dua.ScriptEngine;
    auto source="auto text=\"日本語\"; missing();";
    RunOptions options;options.sourceName=`C:\ゲーム\script\actor.dua`;
    auto result=engine.runSafe(source,options);
    assert(!result.ok);
    assert(result.diagnostic.sourceName==options.sourceName);
    assert(result.diagnostic.line==1 && result.diagnostic.column==source.indexOf("missing")+1);
    assert(result.diagnostic.hasSourceText && result.diagnostic.sourceText==source);
    try{engine.run(source,options);assert(false);}catch(Exception error){
        auto diagnostic=engine.diagnostic(error);
        assert(diagnostic.sourceName==options.sourceName && diagnostic.column==result.diagnostic.column);
    }
    auto syntax=engine.runSafe("auto value = ;",options);
    assert(!syntax.ok && syntax.diagnostic.line==1 && syntax.diagnostic.column>0);
    auto lexer=engine.runSafe("auto value=\"unfinished",options);
    assert(!lexer.ok && lexer.diagnostic.line==1 && lexer.diagnostic.column>0);
    Dua.ScriptDiagnostic unknown=Dua.scriptDiagnostic(new Exception("fake at 99:88 [expression @ C:/fake.dua:8:9]"));
    assert(!unknown.sourceName.length && unknown.line==0 && unknown.column==0);
    options.typeCheck=true;
    auto typed=engine.runSafe("int count=\"bad\";",options);
    assert(!typed.ok && typed.diagnostic.line==1 && typed.diagnostic.column>0);
    options.typeCheck=false;
    auto interpolation="\n\nreturn i\"日本語$(missing)\";";
    auto interpolated=engine.runSafe(interpolation,options);
    assert(!interpolated.ok && interpolated.diagnostic.line==3);
    assert(interpolated.diagnostic.column==interpolation[interpolation.lastIndexOf('\n')+1..$].indexOf("missing")+1);
    auto trailingInterpolation="\nreturn i\"日本語$(1 2)\";";
    auto trailing=engine.runSafe(trailingInterpolation,options);
    assert(!trailing.ok && trailing.diagnostic.line==2);
    assert(trailing.diagnostic.column==trailingInterpolation[1..$].indexOf("2)")+1);
    foreach(invalid;["export { auto x=1; }","foreach(a,b; 1..2) {}", "void f(){instance int n;}",
        "export instance {}", "instance void f(){}", "auto a=1;auto b=2;a,b += 3;",
        "auto a=1;a += 2,3;", "1,2;", "struct S{...Base}", "1 += 2;"]){
        auto validation=engine.runSafe(invalid,options);
        assert(!validation.ok && validation.diagnostic.line>0 && validation.diagnostic.column>0,invalid);
    }
    auto instanceSource="\ninstance int n=1;";
    auto instanceRun=engine.runSafe(instanceSource,options),instanceLoad=engine.loadSafe(instanceSource,options);
    assert(!instanceRun.ok && instanceRun.diagnostic.line==2 && instanceRun.diagnostic.column==10);
    assert(!instanceLoad.ok && instanceLoad.diagnostic.line==2 && instanceLoad.diagnostic.column==10);
    auto emptyInstance=engine.runSafe("\ninstance {}",options);
    assert(!emptyInstance.ok && emptyInstance.diagnostic.line==2 && emptyInstance.diagnostic.column==1);
    auto limitOptions=options;limitOptions.limits.maxSteps=2;
    auto stepLimit=engine.runSafe("1;\n2;",limitOptions);
    assert(!stepLimit.ok && stepLimit.errorKind==RunErrorKind.stepLimit);
    assert(stepLimit.diagnostic.line==2 && stepLimit.diagnostic.column==1);
    limitOptions.limits.maxSteps=1;
    auto expressionLimit=engine.runSafe("1;",limitOptions);
    assert(!expressionLimit.ok && expressionLimit.diagnostic.line==1 && expressionLimit.diagnostic.column==1);
    auto inner=new Dua.ScriptEngine;
    RunOptions innerOptions;innerOptions.sourceName="inner.dua";
    engine.bindNative("wrapped",(scope const(Value)[] args){
        try{inner.run("return missing;",innerOptions);}catch(Exception error){throw new Exception("host wrapper",error);}
        return Value.nullValue();
    });
    auto wrapped=engine.runSafe("wrapped();",options);
    assert(!wrapped.ok && wrapped.diagnostic.sourceName=="inner.dua" && wrapped.diagnostic.column==8);
    auto sameNameSource="void fail(){missing();}";
    assert(engine.loadSafe(sameNameSource,options).ok);
    auto sameName=engine.runSafe("fail();",options);
    assert(!sameName.ok && sameName.diagnostic.sourceText==sameNameSource,"Same sourceName does not imply same compilation snapshot");
    engine.registerModule("worker","export void work(){yield 1;}");
    auto caller="import worker;auto co=coroutine.create(worker.work);coroutine.resume(co);missing();";
    auto afterYield=engine.runSafe(caller,options);
    assert(!afterYield.ok && afterYield.diagnostic.sourceName==options.sourceName);
    assert(afterYield.diagnostic.sourceText==caller,"Yield must restore the caller's source snapshot");
    auto workerSource="export void fail(){\n missing();\n}";
    engine.registerModule("wrappedWorker",workerSource);
    auto wrapCaller="import wrappedWorker;auto wrapped=coroutine.wrap(wrappedWorker.fail);wrapped();";
    auto wrapFailure=engine.runSafe(wrapCaller,options);
    assert(!wrapFailure.ok && wrapFailure.diagnostic.sourceName=="wrappedWorker");
    assert(wrapFailure.diagnostic.line==2 && wrapFailure.diagnostic.column==2);
    assert(wrapFailure.diagnostic.sourceText==workerSource);
    auto handled=engine.runSafe("import wrappedWorker;auto handledCo=coroutine.create(wrappedWorker.fail);auto resumeResult=coroutine.resume(handledCo);return resumeResult[0];",options);
    assert(handled.ok && !handled.value.truthy(),"resume still returns a handled failure without throwing");
}

unittest
{
    auto root=buildPath(tempDir(),"dua-diagnostics-"~randomUUID().toString());mkdir(root);
    scope(exit){enforce(root.baseName.startsWith("dua-diagnostics-"));rmdirRecurse(root);}
    auto file=buildPath(root,"actor.dua");
    auto original="export void step(){\n auto text=\"日本語\"; missing();\n}";
    std.file.write(file,original);
    auto engine=new Dua.ScriptEngine;
    engine.bindAuto("__testPaths",[buildPath(root,"?.dua")]);
    engine.run("package.path=__testPaths;");
    auto moduleHandle=engine.instantiateModule("actor");
    std.file.write(file,"export void step(){}");
    try{moduleHandle.call("step");assert(false);}catch(Exception error){
        auto diagnostic=engine.diagnostic(error);
        assert(diagnostic.sourceName==file && diagnostic.line==2 && diagnostic.column>0);
        assert(diagnostic.hasSourceText && diagnostic.sourceText==original,"Must retain executed source rather than reread edited file");
    }
    std.file.write(file,"export void step( {");
    auto broken=new Dua.ScriptEngine;
    broken.bindAuto("__testPaths",[buildPath(root,"?.dua")]);broken.run("package.path=__testPaths;");
    try{broken.instantiateModule("actor");assert(false);}catch(Exception error){
        auto diagnostic=broken.diagnostic(error);
        assert(diagnostic.sourceName==file && diagnostic.line==1 && diagnostic.column>0);
    }
    std.file.write(file,original);
    auto cached=new Dua.ScriptEngine;
    auto handle=cached.loadModuleFile(file);
    std.file.write(file,"export void step(){}");
    assert(cached.loadModuleFileSafe(file).ok);
    try{handle.call("step");assert(false);}catch(Exception error){
        assert(cached.diagnostic(error).sourceText==original,"Cached AST must keep its own original source");
    }
    std.file.write(file,"void callback(){return missing;}");
    auto globalEngine=new Dua.ScriptEngine;globalEngine.loadFile(file);
    auto callbackSource=readText(file);std.file.write(file,"void callback(){}");
    try{globalEngine.call("callback");assert(false);}catch(Exception error){
        auto diagnostic=globalEngine.diagnostic(error);
        assert(diagnostic.sourceName==file && diagnostic.hasSourceText && diagnostic.sourceText==callbackSource);
    }
}
