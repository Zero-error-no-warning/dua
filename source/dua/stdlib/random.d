module dua.stdlib.random;

import dua;
import std.exception : enforce;
import std.math : isFinite;
import std.random : Random, choice, dice, uniform, uniform01, unpredictableSeed;

// structを引数変換のたびにコピーすると乱数列が進まないため、Duaでは参照として状態を保持します。
private class DuaRandomState {
    private Random _rng;
    enum uint defaultSeed=Random.defaultSeed;
    static @property uint min(){return Random.min;}
    static @property uint max(){return Random.max;}
    @property bool empty() const{return false;}

    this(long value=defaultSeed){seed(value);}
    void seed(long value=defaultSeed){
        enforce(value>=0 && value<=uint.max,"Random seed must be in [0, 4294967295]");
        _rng.seed(cast(uint)value);
    }
    @property uint front() const{return _rng.front;}
    void popFront(){_rng.popFront();}
    @property DuaRandomState save() const{
        auto result=new DuaRandomState();result._rng=_rng;return result;
    }
}

private DuaRandomState generator(const Dua.Value value){
    auto result=value.to!DuaRandomState;
    enforce(result !is null,"Expected a Random instance");
    return result;
}

private bool generatorArgument(const Dua.Value value){
    return value.kind==Dua.ValueKind.table || value.kind==Dua.ValueKind.struct_;
}

private double number(const Dua.Value value,string name){
    enforce(value.kind==Dua.ValueKind.integer || value.kind==Dua.ValueKind.floating,
        name~" expects a number");
    auto result=value.to!double;
    enforce(isFinite(result),name~" expects a finite number");
    return result;
}

private size_t count(const Dua.Value value,string name){
    enforce(value.kind==Dua.ValueKind.integer && value.integerValue>=0,
        name~" expects a non-negative integer");
    enforce(cast(ulong)value.integerValue<=size_t.max,name~" count is too large");
    return cast(size_t)value.integerValue;
}

private Dua.Value[] elements(const Dua.Value value,string name){
    enforce(value.kind==Dua.ValueKind.array,name~" expects an array");
    auto result=new Dua.Value[value.arrayValue.length];
    foreach(i,item;value.arrayValue)result[i]=item.valueCopy();
    return result;
}

private Dua.Value uniformValue(string boundaries)(const Dua.Value low,const Dua.Value high,ref Random rng){
    if(low.kind==Dua.ValueKind.integer && high.kind==Dua.ValueKind.integer)
        return Dua.Value.from(uniform!boundaries(low.integerValue,high.integerValue,rng));
    auto a=number(low,"random.uniform");
    auto b=number(high,"random.uniform");
    // std.randomは区間幅へRNGの整数値を掛けるため、中間計算も有限に収まる必要があります。
    enforce(isFinite((b-a)*cast(double)(rng.max-rng.min)),"random.uniform interval is too large");
    return Dua.Value.from(uniform!boundaries(a,b,rng));
}

package(dua) void installRandomLibrary(Dua.ScriptEngine engine,Dua.ModuleHandle moduleHandle){
    moduleHandle.bind("Random",engine.bindFallbackType!DuaRandomState("Random"));
    if(engine.completionRegistry !is null)
        engine.completionRegistry.typeBinding!DuaRandomState("random.Random",moduleHandle.get("Random"));
    // seedの変更が別のScriptEngineやホスト側の乱数列へ影響しないよう、状態を共有しません。
    // Constructing metadata never draws entropy or advances any generator.
    DuaRandomState cachedRng;
    DuaRandomState defaultGenerator(){
        if(cachedRng is null)cachedRng=new DuaRandomState(unpredictableSeed!uint);
        return cachedRng;
    }
    moduleHandle.bindNative("uniform01",(scope const(Dua.Value)[] args){
        enforce(args.length<=1,"random.uniform01 expects an optional Random");
        auto source=args.length ? generator(args[0]) : defaultGenerator();
        return Dua.Value.from(uniform01(source._rng));
    });
    moduleHandle.bindFunc!(() => unpredictableSeed!uint)("unpredictableSeed");
    moduleHandle.bindNative("seed",(scope const(Dua.Value)[] args){
        enforce(args.length==1,"random.seed expects one uint seed");
        auto seed=count(args[0],"random.seed");
        enforce(seed<=uint.max,"random.seed must be in [0, 4294967295]");
        defaultGenerator().seed(seed);
        return Dua.Value.nullValue();
    });
    moduleHandle.bindNative("uniform",(scope const(Dua.Value)[] args){
        enforce(args.length>=2 && args.length<=4,"random.uniform expects low, high, optional boundaries and Random");
        auto boundaries="[)";
        auto source=defaultGenerator();
        bool hasBoundaries,hasGenerator;
        foreach(arg;args[2..$]){
            if(arg.kind==Dua.ValueKind.string_){
                enforce(!hasBoundaries,"random.uniform accepts one boundaries string");
                boundaries=arg.stringValue;hasBoundaries=true;
            }else{
                enforce(!hasGenerator,"random.uniform accepts one Random");
                source=generator(arg);hasGenerator=true;
            }
        }
        // DuaにはDの文字列テンプレート引数がないため、区間指定を通常引数で受け取ります。
        switch(boundaries){
            static foreach(interval;["[)","[]","(]","()"]){
                case interval:return uniformValue!interval(args[0],args[1],source._rng);
            }
            default:throw new Exception("random.uniform boundaries must be [), [], (] or ()");
        }
    });
    moduleHandle.bindNative("choice",(scope const(Dua.Value)[] args){
        enforce(args.length==1 || args.length==2,"random.choice expects an array and optional Random");
        auto values=elements(args[0],"random.choice");
        enforce(values.length>0,"random.choice array must not be empty");
        auto source=args.length==2 ? generator(args[1]) : defaultGenerator();
        return choice(values,source._rng);
    });
    moduleHandle.bindNative("dice",(scope const(Dua.Value)[] args){
        // std.random同様、重み配列と可変長の数値引数をどちらも受け付けます。
        auto weights=args;
        auto source=defaultGenerator();
        bool hasGenerator;
        if(weights.length && generatorArgument(weights[0])){
            source=generator(weights[0]);weights=weights[1..$];hasGenerator=true;
        }
        if(weights.length && generatorArgument(weights[$-1])){
            enforce(!hasGenerator,"random.dice accepts one Random");
            source=generator(weights[$-1]);weights=weights[0..$-1];
        }
        if(weights.length==1 && weights[0].kind==Dua.ValueKind.array)weights=weights[0].arrayValue;
        enforce(weights.length>0,"random.dice expects at least one weight");
        double[] proportions;
        double total=0;
        foreach(weight;weights){
            auto value=number(weight,"random.dice");
            enforce(value>=0,"random.dice weights must be non-negative");
            proportions~=value;
            total+=value;
        }
        enforce(isFinite(total) && total>0,"random.dice weights must have a finite positive sum");
        // 大きな有限の重みでもstd.random内部の乱数スケーリングがoverflowしないよう正規化します。
        foreach(ref proportion;proportions)proportion/=total;
        return Dua.Value.from(cast(long)dice(source._rng,proportions));
    });
}

unittest {
    auto engine=new Dua.ScriptEngine();
    engine.standardLibraryModule("random");
    auto unit=engine.run(`import random; return random.uniform01();`);
    assert(unit.kind==Dua.ValueKind.floating && unit.to!double>=0 && unit.to!double<1);
    foreach(i;0..128){
        auto integer=engine.run(`import random; return random.uniform(-3, 7);`);
        assert(integer.kind==Dua.ValueKind.integer && integer.to!long>=-3 && integer.to!long<7);
        auto floating=engine.run(`import random; return random.uniform(-3, 7.0);`);
        assert(floating.kind==Dua.ValueKind.floating && floating.to!double>=-3 && floating.to!double<7);
    }
    assert(engine.run(`import random; return random.uniform(5, 6);`).to!long==5);
    assert(engine.run(`import random; return random.uniform(5, 5, "[]");`).to!long==5);
    assert(engine.run(`import random; return random.uniform(5.0, 5.0, "[]");`).to!double==5);
    assert(engine.run(`import random; return random.uniform(5, 6, "(]");`).to!long==6);
    assert(engine.run(`import random; return random.uniform(5, 7, "()");`).to!long==6);
    engine.bindAuto("minimum",long.min);engine.bindAuto("maximum",long.max);
    assert(engine.run(`import random; return random.uniform(minimum, minimum+1);`).to!long==long.min);
    assert(engine.run(`import random; return random.uniform(maximum, maximum, "[]");`).to!long==long.max);
    assert(engine.run(`import random; return random.uniform(minimum, maximum, "[]");`).kind==Dua.ValueKind.integer);
    auto seed=engine.run(`import random; return random.unpredictableSeed();`);
    assert(seed.kind==Dua.ValueKind.integer && seed.to!long>=0 && seed.to!long<=uint.max);
}

unittest {
    auto engine=new Dua.ScriptEngine();
    engine.standardLibraryModule("random");
    assert(engine.run(`import random; return random.choice(["only"]);`).to!string=="only");
    assert(engine.run(`import random; return random.choice([{answer=42}]).answer;`).to!long==42);
    assert(engine.run(`import random; return random.dice([0, 1, 0]);`).to!long==1);
    assert(engine.run(`import random; return random.dice(0, 0.5, 0);`).to!long==1);
    engine.bindAuto("huge",double.max);
    assert(engine.run(`import random; return random.dice(0, huge, 0);`).to!long==1);
    assert(engine.run(`import random; auto input=[0, 1, 2]; random.choice(input); return input;`).to!(long[])==[0,1,2]);
}

unittest {
    auto engine=new Dua.ScriptEngine();engine.standardLibraryModule("random");
    engine.bind("rng",engine.run(`import random; return random.Random(42);`));
    auto native=Random(42);
    foreach(i;0..8){
        assert(engine.run(`import random; return random.uniform(0, 100, rng);`).to!long==uniform(0L,100L,native));
        assert(engine.run(`import random; return random.uniform01(rng);`).to!double==uniform01(native));
        assert(engine.run(`import random; return random.choice([10, 20, 30], rng);`).to!long==choice([10L,20,30],native));
        assert(engine.run(`import random; return random.dice(rng, 0, 1, 0);`).to!long==dice(native,0.0,1.0,0.0));
        assert(engine.run(`return rng.front;`).to!long==native.front);
        engine.run(`rng.popFront();`);native.popFront();
    }
    engine.run(`rng.seed(42);`);
    native.seed(42);
    assert(engine.run(`import random; return random.uniform(0, 100, rng);`).to!long==uniform(0L,100L,native));
    assert(engine.run(`import random; return random.uniform(5, 5, "[]", rng);`).to!long==5);
    assert(engine.run(`import random; return random.uniform(5, 5, rng, "[]");`).to!long==5);
    assert(engine.run(`import random; return random.dice([0, 1, 0], rng);`).to!long==1);
    assert(engine.run(`import random; return random.dice(rng, [0, 1, 0]);`).to!long==1);
    engine.bind("copy",engine.run(`return rng.save;`));
    foreach(i;0..8)
        assert(engine.run(`import random; return random.uniform01(rng);`).to!double
            ==engine.run(`import random; return random.uniform01(copy);`).to!double);
    engine.bind("other",engine.run(`import random; return random.Random.new(42);`));
    engine.run(`rng.seed(42);`);
    assert(engine.run(`import random; return random.uniform01(other);`).to!double
        ==engine.run(`import random; return random.uniform01(rng);`).to!double);
    engine.run(`rng.seed();`);
    assert(engine.run(`return rng.front;`).to!long==Random().front);
    assert(engine.run(`import random; return random.Random().front;`).to!long==Random().front);
    assert(engine.run(`import random; return random.Random.min;`).to!long==Random.min);
    assert(engine.run(`import random; return random.Random.max;`).to!long==Random.max);
    assert(engine.run(`return rng.min;`).to!long==Random.min);
    assert(engine.run(`return rng.max;`).to!long==Random.max);
    assert(engine.run(`return rng.empty;`).to!bool==false);
    import std.exception : assertThrown;
    foreach(expression;["rng.seed(-1)","rng.seed(4294967296)",
        "random.uniform(0, 10, {})","random.choice([1], {})",
        "random.uniform(0, 10, rng, rng)","random.uniform(0, 10, \"[]\", \"[]\")",
        "random.dice(rng, 1, other)"])
        assertThrown!Exception(engine.run("import random; "~expression~";"));
}

unittest {
    import std.random : rndGen;
    auto first=new Dua.ScriptEngine();auto second=new Dua.ScriptEngine();
    first.standardLibraryModule("random");
    second.standardLibraryModule("random");
    auto sequence=q{
        import random;
        return [random.uniform01(), random.uniform(0, 100), random.uniform(0.0, 1.0),
            random.choice([10, 20, 30]), random.dice(1, 2, 3)];
    };
    // モジュール再importでseedがリセットされず、他engineの操作でも列が変わらないことを確認します。
    first.run(`import random; random.seed(42);`);second.run(`import random; random.seed(42);`);
    auto expected=first.run(sequence).toHostString();
    assert(second.run(sequence).toHostString()==expected);
    assert(first.run(sequence).toHostString()==second.run(sequence).toHostString());
    first.run(`import random; random.seed(42);`);
    second.run(`import random; random.seed(99); random.uniform01();`);
    assert(first.run(sequence).toHostString()==expected);
    first.run(`import random; random.seed(0); random.seed(4294967295);`);
    auto saved=rndGen;
    scope(exit)rndGen=saved;
    auto host=rndGen;
    first.run(sequence);
    assert(rndGen.front==host.front);
}

unittest {
    import std.exception : assertThrown;
    auto engine=new Dua.ScriptEngine();
    engine.standardLibraryModule("random");
    engine.bindAuto("nan",double.nan);engine.bindAuto("infinity",double.infinity);engine.bindAuto("huge",double.max);
    foreach(expression;[
        "uniform01(1)","unpredictableSeed(1)","seed()","seed(-1)","seed(4294967296)","seed(1.5)","seed(true)",
        "uniform()","uniform(3, 2)","uniform(2, 2)","uniform(2, 2, \"()\")","uniform(2, 3, \"()\")",
        "uniform(false, 2)","uniform(\"0\", 2)","uniform(nan, 2)","uniform(0, infinity)","uniform(0.0, huge)",
        "uniform(0, 2, \"invalid\")","uniform(0, 2, 3)","uniform(0, 2, \"[]\", 4)",
        "choice([])","choice(3)","choice([1], 2)","dice()","dice([])","dice(0, 0)",
        "dice(-1, 2)","dice(nan)","dice(infinity)","dice(huge, huge)","dice(\"1\")","dice(true)",
        "uniform01(null)","uniform(0, 2, null)","dice({})","Random(-1)","Random(4294967296)"
    ])assertThrown!Exception(engine.run("import random; return random."~expression~";"));
}
