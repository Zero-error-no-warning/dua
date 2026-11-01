module lazy_arguments;
import dua.runtime;
import std.exception : enforce;
import std.stdio : writeln;

void main()
{
    foreach (checked; [false, true])
    {
        auto engine = new ScriptEngine;
        RunOptions options;
        options.typeCheck = checked;
        enforce(engine.run(q{
            int n = 0;
            int bump() { n = n + 1; return n; }
            int skip(lazy int x) { return 9; }
            int twice(lazy int x) { return x + x; }
            int forward(lazy int x) { return twice(x); }
            auto a = skip(bump());
            auto b = forward(bump());
            auto f = (lazy int x) => x + x;
            return a == 9 && b == 3 && f(bump()) == 7 && n == 4;
        }, options).truthy());
        enforce(engine.run(q{
            any capture(lazy int x) { return () => x; }
            int n = 0;
            int next() { n = n + 1; return n; }
            auto saved = capture(next());
            return n == 0 && saved() == 1 && saved() == 2;
        }, options).truthy());
        enforce(engine.run(q{
            int read(lazy int x) { int local = 20; return x; }
            int local = 7;
            return read(local) == 7;
        }, options).truthy());
        enforce(!engine.runSafe(`int bad(lazy int x = 1) { return x; }`, options).ok);
        enforce(!engine.runSafe(`int bad(lazy int x...) { return 0; }`, options).ok);
        enforce(!engine.runSafe(`int bad(lazy int x) { x = 2; return x; } return bad(1);`, options).ok);
    }
    auto engine=new ScriptEngine;
    auto context=engine.createModuleContext();
    auto module_=engine.newContextModule(context,"lazy.owner");
    auto saved=module_.run(q{
        any capture(lazy int value){return () => value;}
        int local=11;
        return capture(local);
    }).functionValue;
    enforce(saved.invoke([]).toInt()==11);
    context.close();
    bool closed;
    try saved.invoke([]); catch(Exception error) {closed=true;}
    enforce(closed,"Closed module must reject retained lazy expressions");
    writeln("lazy language tests passed (type checking on/off)");
}
