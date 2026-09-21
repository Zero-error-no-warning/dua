module dua.associative_array_tests;

version (unittest):

import dua;
import std.algorithm : canFind;
import std.exception : assertThrown;

private struct PointKey
{
    int x;
    int y;
    this(int x, int y) { this.x = x; this.y = y; }
}
private struct EqualKey
{
    int id;
    int ignored;
    this(int id, int ignored) { this.id = id; this.ignored = ignored; }
    bool opEquals(const EqualKey rhs) const { return id == rhs.id; }
    size_t toHash() const { return cast(size_t) id; }
}
private class ObjectKey { int id; }
private string chooseKeys(string[int] items) { return "integer"; }
private string chooseKeys(string[string] items) { return "string"; }

unittest
{
    // Compare indexed storage with the original ordered linear model while
    // crossing the index threshold, replacing, removing and reinserting keys.
    auto actual = Value.associativeArray();
    auto aliasValue = actual;
    AssociativeEntry[] expected;
    Value[] keys = [Value.nullValue(), Value.from(false), Value.from(true),
        Value.from(0), Value.from(1), Value.from(long.min), Value.from(long.max),
        Value.from(0.0), Value.from(-0.0), Value.from(1.0), Value.from(-1.5),
        Value.from(double.min_normal), Value.from(double.max), Value.from(""),
        Value.from("1"), Value.from("日本語"), Value.from("a\0b")];
    foreach (i; 0 .. 40) keys ~= Value.from(i + 10);
    foreach (step; 0 .. 600)
    {
        auto key = keys[(step * 17) % keys.length];
        size_t found = size_t.max;
        foreach (index, entry; expected)
            if (entry.key.kind == key.kind && valuesEqual(entry.key, key))
            {
                found = index;
                break;
            }
        if (step % 5 == 0)
        {
            assert(actual.associativeRemove(key) == (found != size_t.max));
            if (found != size_t.max)
                expected = expected[0 .. found] ~ expected[found + 1 .. $];
        }
        else
        {
            auto value = Value.from(step);
            actual.associativeSet(key, value);
            if (found == size_t.max) expected ~= AssociativeEntry(key, value);
            else expected[found].value = value;
        }
        assert(aliasValue.associativeEntries.length == expected.length);
        foreach (index, entry; expected)
        {
            assert(actual.associativeIndex(entry.key) == index);
            assert(valuesEqual(cast(Value) aliasValue.associativeEntries[index].key, entry.key));
            assert(aliasValue.associativeEntries[index].value.toInt() == entry.value.toInt());
        }
    }
    // Non-finite keys are still rejected, without damaging the index.
    auto count = actual.associativeEntries.length;
    foreach (number; [double.nan, double.infinity, -double.infinity])
    {
        assert(actual.associativeIndex(Value.from(number)) == size_t.max);
        assertThrown!Exception(actual.associativeSet(Value.from(number), Value.from(1)));
        assert(actual.associativeEntries.length == count);
    }
    foreach (entry; expected) assert(actual.associativeRemove(entry.key));
    assert(actual.associativeEntries.length == 0);
    actual.associativeSet(Value.from(-0.0), Value.from(1));
    actual.associativeSet(Value.from(0.0), Value.from(2));
    assert(actual.associativeEntries.length == 1);
    assert(actual.associativeEntries[0].value.toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!EqualKey("EqualKey");
    engine.bindAuto("objectKey", new ObjectKey());
    assert(engine.run(q{
        struct Point { int x; int y; }
        auto items = [null: 0, true: 1, 1: 2, 1.0: 3, "1": 4,
            [1, 2]: 5, Point(1, 2): 6, EqualKey(1, 2): 7, objectKey: 8];
        items[EqualKey(1, 9)] = 70;
        items[[1, 2]] = 50;
        items[Point(1, 2)] = 60;
        auto shared = items;
        auto before = items.keys;
        items.remove(true);
        items.remove([1, 2]);
        items[true] = 10;
        auto after = items.keys;
        auto ordered = after[0] == null && after[1] == 1 && after[2] == 1.0
            && after[3] == "1" && after[4] == Point(1, 2) && after[5].id == 1
            && after[5].ignored == 2 && after[6] == objectKey && after[7] == true;
        auto valid = items[EqualKey(1, 3)] == 70 && items[Point(1, 2)] == 60
            && items[objectKey] == 8 && !items.contains([1, 2]) && items[true] == 10;
        auto visited = 0;
        foreach (key, value; items) {
            visited += 1;
            items.remove(key);
        }
        return valid && length(before) == 9 && before[1] == true && before[5] == [1, 2]
            && ordered && visited == 8 && shared.length == 0;
    }).truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    RunOptions options;
    options.typeCheck = true;
    auto result = engine.run(q{
        string[int] names = [1: "Alice", 2: "Bob",];
        names[3] = "Carol";
        names[1] = "Ada";
        auto shared = names;
        shared[2] = "Bea";
        string[int] empty;
        string[int] another = [];
        int[int] numbers = [:];
        numbers[4] = 40;
        auto count = 0;
        foreach (key, value; names) {
            if (key == 3) { continue; }
            count = count + 1;
        }
        auto sum = 0;
        foreach (value; numbers) { sum = sum + value; }
        auto mixed = [7: "integer", "7": "string", true: "boolean"];
        auto oldTable = { [7] = "first", ["7"] = "last" };
        return names[1] == "Ada" && names[2] == "Bea" && names.length == 3
            && length(empty) == 0 && another.length == 0 && count == 2 && sum == 40
            && names.contains(3) && !names.contains(9)
            && names.get(9, "missing") == "missing" && names.get(1, "missing") == "Ada"
            && names.remove(3) && !names.remove(3) && names.length() == 2
            && length(names.keys) == 2 && length(names.values()) == 2
            && mixed[7] == "integer" && mixed["7"] == "string" && mixed[true] == "boolean"
            && length(mixed) == 3 && length(oldTable) == 1
            && typeof(names).kind == "associativeArray" && typeof(oldTable).kind == "table"
            && typeof(names).keyType == "int" && typeof(names).valueType == "string"
            && names is string[int] && !(names is table);
    }, options);
    assert(result.truthy());
    assert(engine.run(q{
        alias Id = int;
        alias Names = string[Id];
        Names names = [1: "Alice"];
        string[int] identity(string[int] value) { return value; }
        auto callback = (string[int] value) => value[1];
        int[int][string] nested = ["team": [1: 10]];
        int[][int] arrays = [2: [3, 4]];
        int[int][] list = [[1: 5]];
        auto explicit = cast(string[int]) [1: "Alice"];
        struct Group { int[int] scores; }
        auto group = Group([1: 20]);
        auto initialized = Group({ scores = [1: 30] });
        return callback(names) == "Alice" && identity(names)[1] == "Alice"
            && nested["team"][1] == 10 && arrays[2][1] == 4 && list[0][1] == 5
            && explicit == names && group.scores[1] == 20 && initialized.scores[1] == 30;
    }, options).truthy());

    foreach (source; [
        `int[int] a = { x = 1 };`,
        `int[int] a = ["1": 2];`,
        `int[int] a = [1: "wrong"];`,
        `int[int] a; a["1"] = 2;`,
        `int[int] a; a[1] = "wrong";`,
        `int[int] a; auto b = a; b[1] = "wrong";`,
        `int[int] a; a = ["1": 2];`,
        `int[int] a; return a[1];`,
        `int[int] a; return a.contains("1");`,
        `int[int] a; return a.remove("1");`,
        `int[int] a; return a.get(1, "wrong");`,
        `int[int] a; return a.foo;`,
        `int[int] a; return a[0 .. 1];`,
        `auto a = [{}: 1];`,
        `auto a = [(0.0 / 0.0): 1];`,
        `auto a = [1: 2, 3];`,
        `auto a = [1, 2: 3];`,
        `int f(int[int] a) { a = ["x": 1]; return 0; } return f([:]);`,
        `auto f = (int[int] a) => a[1]; return f(["1": 2]);`,
        `string[int] f() { return [1: 2]; } return f();`,
        `int[int] a; return json.encode(a);`
    ])
    {
        auto failure = engine.runSafe(source);
        assert(!failure.ok, source);
    }
    assert(engine.check(`int[int] a; a["1"] = 2;`).length > 0);
    assert(engine.check(`int[int] a; a[1] = "wrong";`).length > 0);
    assert(engine.check(`int[int] a; return a["1"];`).length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindFunc!((string[int] names) => names[1])("firstName");
    engine.bindFunc!((int[bool] flags) => flags[true])("flag");
    engine.bindFunc!((string[double] values) => values[1.5])("fraction");
    engine.bindFunc!((int[int][string] values) => values["team"][1])("nested");
    engine.bindFunc!((int[PointKey] values) => values[PointKey(1, 2)])("pointValue");
    engine.bindFunc!((int[int[]] values) => values[[1, 2]])("arrayKey");
    engine.bindFunc!chooseKeys("chooseKeys");
    assert(engine.run(`string[int] n = [1: "Alice"]; return firstName(n);`).toHostString() == "Alice");
    assert(engine.run(`int[bool] a = [true: 42]; return flag(a);`).toInt() == 42);
    assert(engine.run(`string[double] a = [1.5: "half"]; return fraction(a);`).toHostString() == "half");
    assert(engine.run(`int[int][string] a = ["team": [1: 42]]; return nested(a);`).toInt() == 42);
    assert(engine.run(`struct PointKey { int x; int y; }
        int[PointKey] a = [PointKey(1, 2): 42]; return pointValue(a);`).toInt() == 42);
    assert(engine.run(`int[int[]] a = [[1, 2]: 42]; return arrayKey(a);`).toInt() == 42);
    assert(engine.run(`string[int] a; return chooseKeys(a);`).toHostString() == "integer");
    assert(engine.run(`string[string] a; return chooseKeys(a);`).toHostString() == "string");
    assert(!engine.runSafe(`string[string] a; return firstName(a);`).ok);
    assert(!engine.runSafe(`return firstName([2147483648: "too big"]);`).ok);

    int[int] original = [1: 42];
    engine.bindAuto("original", original);
    engine.bindFunc!(() => [1: "returned"])("returnNames");
    engine.bindFunc!(() => [1: ["score": 42]])("returnNested");
    assert(engine.run(`original[1] = 43; return original[1];`).toInt() == 43);
    assert(original[1] == 42);
    assert(engine.run(`return returnNames()[1];`).toHostString() == "returned");
    assert(engine.run(`return returnNested()[1]["score"];`).toInt() == 42);
    engine.bind("typedString", Value.fromAssociativeArray(["a": 42]));
    assert(engine.run(`return typeof(typedString).kind == "associativeArray" && typedString["a"] == 42;`).truthy());
    assert(engine.run(`int[int] a = [1: 42]; return a;`).to!(int[int])() == original);
    assertThrown!Exception(engine.run(`return [1: "integer", "1": "string"];`).to!(string[int])());
    assertThrown!Exception(engine.run(`return [1: 10, 1.0: 20];`).to!(int[double])());
    assertThrown!Exception(Value.from([ulong.max: 1]));
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!PointKey("PointKey");
    engine.bindType!EqualKey("EqualKey");
    auto objectA = new ObjectKey();
    auto objectB = new ObjectKey();
    engine.bindAuto("objectA", objectA);
    engine.bindAuto("objectB", objectB);
    engine.bindFunc!((int[ObjectKey] values) => values.length)("countObjects");
    assert(engine.run(q{
        auto point = PointKey(1, 2);
        string[PointKey] points = [point: "saved"];
        point.x = 9;
        auto exposed = points.keys[0];
        exposed.x = 8;
        auto array = [1, 2];
        string[int[]] arrays = [array: "saved"];
        array[0] = 9;
        auto keys = arrays.keys;
        keys[0][0] = 8;
        string[EqualKey] custom = [EqualKey(1, 2): "first", EqualKey(1, 9): "last"];
        int[ObjectKey] objects = [objectA: 1, objectB: 2];
        return points[PointKey(1, 2)] == "saved" && !points.contains(point)
            && arrays[[1, 2]] == "saved" && custom.length == 1
            && custom[EqualKey(1, 3)] == "last" && countObjects(objects) == 2;
    }).truthy());
    auto saved = engine.run(`string[int] a = [1: "saved"]; return a;`);
    assert(engine.run("return " ~ saved.toScriptLiteral() ~ ";").to!(string[int])()[1] == "saved");
}
