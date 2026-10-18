module dua.string_literal_type_tests;

version (unittest):
import dua;
import std.algorithm : canFind;
private class LiteralItem { int value = 7; }

private void accepts(string source)
{
    auto diagnostics = (new ScriptEngine).check(source);
    assert(diagnostics.length == 0, source ~ (diagnostics.length ? "\n" ~ diagnostics[0].message : ""));
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked;
        auto result = (new ScriptEngine).runSafe(source, options);
        assert(result.ok && result.value.truthy(), source ~ "\n" ~ result.errorMessage);
    }
}

private void rejects(string source, bool staticallyKnown = true)
{
    if (staticallyKnown)
    {
        auto diagnostics = (new ScriptEngine).check(source);
        assert(diagnostics.length > 0, source);
        assert(diagnostics[0].line > 0 && diagnostics[0].column > 0, source);
    }
    foreach (checked; [false, true])
    {
        RunOptions options; options.typeCheck = checked; options.sourceName = "fruit.dua";
        auto result = (new ScriptEngine).runSafe(source, options);
        assert(!result.ok, source);
        assert(result.diagnostic.line > 0 && result.diagnostic.column > 0, result.errorMessage);
        assert(result.diagnostic.sourceName == "fruit.dua", result.errorMessage);
    }
}

unittest
{
    accepts(q{
        alias Apple = "Apple";
        alias Fruit = Apple | "Orange" | Apple | "Orange";
        alias Basket = Fruit;
        Basket fruit = "Apple";
        fruit = "Orange";
        Fruit identity(Fruit value) { return value; }
        string text = identity(fruit);
        auto ordinary = "Apple"; ordinary = "Banana";
        return text == "Orange" && ordinary == "Banana" && fruit is Fruit;
    });
    accepts(q{
        alias Mixed = "Apple" | int | null;
        Mixed value = 3; value = "Apple"; value = null;
        alias Broad = "Apple" | string;
        Broad text = "Banana";
        alias NumberOrText = int | string;
        NumberOrText existing = "Orange"; existing = 7;
        return value == null && text == "Banana" && existing == 7;
    });
    accepts(q{
        alias Special = "" | "りんご" | "a|b" | "a[b]" | " delegate(" | "C:\fruit\new";
        Special text = "C:\fruit\new";
        Special[] values = ["", "りんご", "a|b", "a[b]", " delegate("];
        values[0] = "C:\fruit\new";
        alias Key = "a]b[";
        int[Key] counts; counts["a]b["] = 2;
        return text == values[0] && counts["a]b["] == 2;
    });
    accepts(q{
        alias Fruit = "Apple" | "Orange";
        Fruit[] values = ["Apple"]; values ~= "Orange";
        Fruit[] identity(Fruit[] value) { return value; }
        table Basket { Fruit fruit; }
        Basket basket = { fruit = "Apple" }; basket.fruit = "Orange";
        return identity(values)[1] == basket.fruit && cast(Fruit) "Apple" == "Apple";
    });
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; `;
    foreach (source; [
        `Fruit fruit = "Banana";`,
        `Fruit fruit = true;`,
        `Fruit fruit = null;`,
        `Fruit fruit = "Apple"; fruit = "Banana";`,
        `void eat(Fruit fruit) {} eat("Banana");`,
        `Fruit pick() { return "Banana"; } pick();`,
        `alias Apple = "Apple"; Apple fruit = "Orange";`,
        `Fruit[] values = ["Apple"]; values[0] = "Banana";`,
        `Fruit[] values = ["Apple"]; values ~= "Banana";`
        , `Fruit[string] values; values["first"] = "Banana";`
        , `int[Fruit] values; values["Banana"] = 1;`
    ]) rejects(prefix ~ source);

    foreach (source; [
        `any value = "Banana"; Fruit fruit = value;`,
        `string value = "Banana"; Fruit fruit = value;`,
        `Fruit fruit = "Apple"; any value = 7; fruit = value;`,
        `void eat(Fruit fruit) {} any value = "Banana"; eat(value);`,
        `Fruit pick() { any value = "Banana"; return value; } pick();`,
        `Fruit[] values = ["Banana"];`,
        `Fruit[] values = ["Apple"]; any value = "Banana"; values[0] = value;`,
        `Fruit[] values = ["Apple"]; any value = "Banana"; values ~= value;`,
        `table Basket { Fruit fruit; } Basket basket = { fruit = "Banana" };`,
        `void eat(Fruit fruit) { any value = "Banana"; fruit = value; } eat("Apple");`,
        `Fruit[string] values; any value = "Banana"; values["first"] = value;`,
        `int[Fruit] values; any key = "Banana"; values[key] = 1;`,
        `return cast(Fruit) "Banana";`
    ]) rejects(prefix ~ source, false);
}

unittest
{
    auto engine = new ScriptEngine;
    engine.bindType!LiteralItem("LiteralItem");
    auto source = q{
        alias Target = LiteralItem | "Apple" | null;
        Target target = null; target = LiteralItem();
        int read(Target value) { return value.value; }
        auto result = read(target); target = "Apple";
        return result == 7 && target == "Apple";
    };
    assert(engine.check(source).length == 0);
    RunOptions options; options.typeCheck = true;
    assert(engine.run(source, options).truthy());
}

unittest
{
    // 通常の文字列と同じ字句規則を保ち、今回エスケープ構文は導入しません。
    rejects("alias Fruit = \"unterminated;", false);
    rejects("alias Fruit = \"line\nbreak\";", false);
    rejects(`alias Fruit = 1 | true;`, false);
    accepts(`alias Apple = "Apple"; Apple[] values = ["Apple"]; return values[0] == "Apple";`);
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; alias Optional = Fruit[] | null; `;
    accepts(prefix ~ q{
        Optional values = null; values = ["Apple"]; values ~= "Orange";
        Optional identity(Optional items) { return items; }
        identity(values)[0] = "Orange";
        return values[0] == "Orange" && values[1] == "Orange";
    });
    foreach (source; [
        `Optional values = ["Banana"];`,
        `Optional values = ["Apple"]; values = ["Banana"];`,
        `Optional values = ["Apple"]; values[0] = "Banana";`,
        `Optional values = ["Apple"]; values ~= "Banana";`,
        `void eat(Optional values) {} eat(["Banana"]);`,
        `void eat(Optional values) { values[0] = "Banana"; } eat(["Apple"]);`,
        `void eat(Optional values) { values ~= "Banana"; } eat(["Apple"]);`,
        `Optional pick() { return ["Banana"]; } pick();`
    ]) rejects(prefix ~ source, false);
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; `;
    accepts(prefix ~ q{
        alias Broad = Fruit[] | string[];
        Broad values = ["Apple"]; values[0] = "Banana";
        values ~= "Orange"; values = ["Banana", "Apple"];
        void change(Broad items) { items[1] = "Banana"; }
        change(values);
        return values[0] == "Banana" && values[1] == "Banana";
    });
    accepts(prefix ~ q{
        alias Mixed = Fruit[] | int[];
        Mixed values = ["Apple", "Orange"];
        values = [1, 2]; values[0] = 3; values ~= 4;
        values = ["Orange"]; values[0] = 9; values[0] = "Apple";
        return values.length == 1 && values[0] == "Apple";
    });
    foreach (source; [
        `Mixed values = ["Apple", 1];`,
        `Mixed values = ["Apple", "Orange"]; values[0] = 1;`,
        `Mixed values = [1, 2]; values[0] = "Apple";`,
        `Mixed values = ["Apple"]; values ~= 1;`,
        `Mixed values = [1]; values ~= "Apple";`,
        `Mixed values = ["Apple"]; values = ["Orange", 1];`,
        `void change(Mixed values) { values[0] = 1; } change(["Apple", "Orange"]);`
    ]) rejects(prefix ~ `alias Mixed = Fruit[] | int[]; ` ~ source, false);
    accepts(prefix ~ q{
        alias Mixed = Fruit[] | int[];
        Mixed values = ["Apple", "Orange"];
        bool rejected = false;
        try { values[0] = 1; } catch (err) { rejected = true; }
        return rejected && values[0] == "Apple" && values[1] == "Orange";
    });
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; alias Row = Fruit[]; alias Grid = Row[] | int[][]; `;
    accepts(prefix ~ q{
        Grid values = [["Apple"]];
        auto row = values[0]; row[0] = 1;
        Grid identity(Grid input) { return input; }
        identity(values)[0][0] = "Orange";
        return row[0] == "Orange" && values[0][0] == "Orange";
    });
    foreach (source; [
        `Grid values = [["Apple"], [1]];`,
        `Grid values = [["Apple"], ["Orange"]]; auto row = values[0]; row[0] = 1;`,
        `Grid values = [["Apple"], ["Orange"]]; values[0] = [1];`,
        `Grid values = [["Apple"]]; values ~= [[1]];`,
        `void change(Grid values) { values[0][0] = 1; } change([["Apple"], ["Orange"]]);`,
        `Grid values = [["Apple"]]; values[0] = ["Banana"];`
    ]) rejects(prefix ~ source, false);
    accepts(prefix ~ q{
        Grid values = [["Apple"], ["Orange"]];
        bool rejected = false;
        auto row = values[0];
        try { row[0] = 1; } catch (err) { rejected = true; }
        values[0] = ["Orange"];
        return rejected && row[0] == "Apple" && values[0][0] == "Orange";
    });
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; alias Mixed = Fruit[] | int[]; `;
    accepts(prefix ~ q{
        Mixed values = ["Apple", "Orange"];
        auto piece = values[0..1]; piece[0] = 1;
        Mixed single = ["Apple"];
        auto joined = single ~ []; joined[0] = 2;
        return values[0] == "Apple" && values[1] == "Orange"
            && piece[0] == 1 && single[0] == "Apple" && joined[0] == 2;
    });
    rejects(prefix ~ `Mixed values = ["Apple", "Orange"]; auto piece = values[0..$]; piece[0] = 1;`, false);
    rejects(prefix ~ `Mixed values = ["Apple"]; auto joined = values ~ ["Orange"]; joined[0] = 1;`, false);
    rejects(prefix ~ q{
        alias Grid = Fruit[][] | int[][];
        Grid values = [["Apple"], ["Orange"]];
        auto piece = values[0..1]; piece[0][0] = 1;
    }, false);
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; `;
    accepts(prefix ~ q{
        int count(Fruit values...) { values[0] = "Orange"; return values.length; }
        int arrayCount(Fruit[] values...) { values[0][0] = "Orange"; return values.length; }
        return count("Apple", "Orange") == 2 && arrayCount(["Apple"], ["Orange"]) == 2;
    });
    foreach (source; [
        `void eat(Fruit values...) {} any value = "Banana"; eat(value);`,
        `void eat(Fruit values...) {} any value = 1; eat(value);`,
        `void eat(Fruit[] values...) {} any value = ["Banana"]; eat(value);`,
        `void eat(Fruit values...) { any bad = "Banana"; values[0] = bad; } eat("Apple");`,
        `void eat(Fruit[] values...) { any bad = "Banana"; values[0][0] = bad; } eat(["Apple"]);`,
        `void eat(Fruit values...) { any bad = "Banana"; values ~= bad; } eat("Apple");`
    ]) rejects(prefix ~ source, false);
}

unittest
{
    enum prefix = `alias Fruit = "Apple" | "Orange"; `;
    accepts(prefix ~ q{
        Fruit fruit = "Apple"; auto copy = fruit; copy = "Banana";
        alias Apple = "Apple"; Apple apple = "Apple";
        auto singleCopy = apple; singleCopy = "Banana";
        return fruit == "Apple" && apple == "Apple" && copy == "Banana" && singleCopy == "Banana";
    });
    accepts(prefix ~ q{
        Fruit[] values = ["Apple"]; auto copy = values; copy[0] = "Orange";
        return values[0] == "Orange";
    });
    rejects(prefix ~ `Fruit[] values = ["Apple"]; auto copy = values; any bad = "Banana"; copy[0] = bad;`, false);
    rejects(prefix ~ `alias Mixed = Fruit[] | int[]; Mixed values = ["Apple", "Orange"]; auto copy = values; copy[0] = 1;`, false);
}

unittest
{
    accepts(q{
        alias Fruit = "Apple" | "Orange";
        alias Mixed = Fruit[] | array;
        auto cycle = [null]; cycle[0] = cycle;
        Mixed value = cycle;
        value[0][0] = 7;
        return value[0] == 7 && cycle[0].length == 1;
    });
    accepts(q{
        alias Fruit = "Apple" | "Orange";
        alias Optional = Fruit[string] | null;
        Fruit[string] typed = ["key":"Apple"];
        Optional value = typed; value["key"] = "Orange";
        return value["key"] == "Orange";
    });
    rejects(`alias Fruit="Apple"|"Orange"; alias Optional=Fruit[string]|null;
        Fruit[string] typed=["key":"Apple"]; Optional value=typed; value["key"]="Banana";`, false);
}

unittest
{
    accepts(q{
        alias Fruit = "Apple" | "Orange";
        alias Grid = Fruit[][] | int[][];
        auto row = ["Apple"];
        Grid values = []; values ~= [row, row];
        values[0][0] = "Orange";
        auto joined = values ~ [values[0]];
        joined[2][0] = "Apple";
        values[1] = values[0]; values[1][0] = "Orange";
        return values[0][0] == "Orange" && values[1][0] == "Orange"
            && joined[2][0] == "Orange" && row[0] == "Apple";
    });
}
