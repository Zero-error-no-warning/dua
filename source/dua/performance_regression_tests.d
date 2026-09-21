module dua.performance_regression_tests;

version (unittest):

import dua;

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        auto trace = "";
        int next(int value) { trace ~= cast(string) value; return value; }
        any choose() {
            trace ~= "c";
            return (int a, int b, int c) => a * 100 + b * 10 + c;
        }
        auto result = choose()(next(1), next(2), next(3));
        auto items = [next(4), ...[next(5), next(6)], next(7)];
        return trace == "123c4567" && result == 123 && items == [4, 5, 6, 7];
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    assert(engine.run(q{
        struct Item { int value; table reference; }
        auto reference = { value = 10 };
        auto original = [Item(1, reference), Item(2, reference)];
        auto spread = [...original];
        auto sliced = original[0..$];
        auto joined = original ~ original;
        auto mapped = map(original, (any item) => item);
        auto filtered = filter(original, (any item) => true);
        spread[0].value = 11;
        sliced[0].value = 12;
        joined[0].value = 13;
        mapped[0].value = 14;
        filtered[0].value = 15;
        spread[0].reference.value = 99;
        return original[0].value == 1 && spread[0].value == 11
            && sliced[0].value == 12 && joined[0].value == 13
            && mapped[0].value == 14 && filtered[0].value == 15
            && original[1].reference.value == 99 && joined[2].value == 1;
    }).truthy());
}
