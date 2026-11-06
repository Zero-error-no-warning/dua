module dua.native_snapshot_tests;
version(unittest):
import dua;
import core.memory : GC;

private struct Cell {
    int number;
    this(int number){this.number=number;}
}
private struct Row {
    Cell cell;
    string label;
    Row painted(int number){auto result=this;result.cell.number=number;return result;}
}
private struct Document {
    Row row;
    Row[] rows;
}

unittest {
    auto engine=new ScriptEngine;
    engine.bindType!Cell("Cell");
    engine.bindAuto("original",Row(Cell(3),"original"));
    // 引数・戻値・別変数・通常関数と軽量coroutineの間で、ネイティブ値の独立性を保ちます。
    auto result=engine.run(q{
        auto copy=original;
        copy.cell=Cell(7);
        copy.label="copy";
        any change(any value){value.cell=Cell(9);value.label="function";return value;}
        auto changed=change(copy);
        auto worker=coroutine.create((){
            auto local=copy.painted(11);
            yield local;
            local.cell=Cell(13);
            return local;
        });
        auto first=coroutine.resume(worker);
        auto second=coroutine.resume(worker);
        return original.cell.number==3 && original.label=="original"
            && copy.cell.number==7 && copy.label=="copy"
            && changed.cell.number==9 && changed.label=="function"
            && first[0] && first[1].cell.number==11
            && second[0] && second[1].cell.number==13;
    });
    assert(result.truthy());
    auto reflected=Value.reflect(Document(Row(Cell(2),"nested"),[Row(Cell(5),"array")]));
    auto copied=reflected.valueCopy();
    auto nested=copied.propertyGetter("row").functionValue.invoke([]);
    auto replacement=Row(Cell(17),"changed");
    copied.propertySetter("row").functionValue.invoke([Value.reflect(replacement)]);
    GC.collect();
    assert(nested.to!Row().cell.number==2);
    assert(reflected.to!Document().row.cell.number==2);
    assert(copied.to!Document().row.cell.number==17);
    assert(copied.to!Document().rows[0].cell.number==5);
}

private struct FrozenFields {
    Row row;
    Row[] rows;
    int[] numbers;
    void mutate(){row.cell.number=90;rows[0].cell.number=91;numbers[0]=92;}
}
private struct CopyEffect {
    static int copies;
    int number;
    this(this){++copies;}
}
private struct EffectFields {CopyEffect effect;}

unittest {
    auto rows=[Row(Cell(5),"array")];
    auto numbers=[7,8];
    auto value=Value.reflect(FrozenFields(Row(Cell(3),"row"),rows,numbers));
    auto copy=value.valueCopy();
    // method/propertyはlive owner、table inspectionは反射時のsnapshotという区別を保ちます。
    value.findMember("mutate").functionValue.invoke([]);
    GC.collect();
    assert(value.to!FrozenFields().row.cell.number==90);
    assert(value.tableValue["row"].to!Row().cell.number==3);
    assert(value.tableValue["rows"].arrayValue[0].to!Row().cell.number==5);
    assert(value.tableValue["numbers"].arrayValue[0].toInt()==7);
    assert(copy.tableValue["row"].to!Row().cell.number==3);
    assert(copy.tableValue["rows"].arrayValue[0].to!Row().cell.number==5);
    assert(copy.tableValue["numbers"].arrayValue[0].toInt()==7);

    auto host=FrozenFields(Row(Cell(11),"host"),[Row(Cell(12),"host array")],[13]);
    auto reflected=Value.reflect(host);
    host.rows[0].cell.number=20;host.numbers[0]=21;
    GC.collect();
    assert(reflected.tableValue["rows"].arrayValue[0].to!Row().cell.number==12);
    assert(reflected.tableValue["numbers"].arrayValue[0].toInt()==13);
    assert(reflected.propertyGetter("rows").functionValue.invoke([]).arrayValue[0].to!Row().cell.number==20);

    auto effect=EffectFields(CopyEffect(4));
    CopyEffect.copies=0;
    auto eager=Value.reflect(effect);
    auto alreadyCopied=CopyEffect.copies;
    assert(alreadyCopied>0);
    auto table=eager.tableValue;
    assert(CopyEffect.copies==alreadyCopied);
    assert(table["effect"].to!CopyEffect().number==4);
}

unittest {
    auto engine=new ScriptEngine;
    engine.bindType!Cell("Cell");
    engine.bindAuto("data",FrozenFields(Row(Cell(3),"row"),[Row(Cell(5),"array")],[7]));
    auto result=engine.run(q{
        auto independent=data;
        auto job=coroutine.create((){
            auto local=data.row.painted(20);
            auto parts=data.rows;
            yield local;
            local.cell=Cell(30);
            return [local,parts[0]];
        });
        auto first=coroutine.resume(job);
        auto second=coroutine.resume(job);
        return first[0] && second[0] && first[1].cell.number==20
            && second[1][0].cell.number==30 && second[1][1].cell.number==5
            && independent.row.cell.number==3 && data.row.cell.number==3;
    });
    assert(result.truthy());
}

private struct VariantFields {
    import std.sumtype : SumType, match;
    SumType!(Row,int) choice;
    void replace(){choice=42;}
}
unittest {
    import std.sumtype : SumType, match;
    auto reflected=Value.reflect(VariantFields(SumType!(Row,int)(Row(Cell(4),"before"))));
    reflected.findMember("replace").functionValue.invoke([]);
    GC.collect();
    assert(reflected.to!VariantFields().choice.match!((Row row)=>false,(int n)=>n==42));
    auto captured=reflected.tableValue["choice"].to!(SumType!(Row,int));
    assert(captured.match!((Row row)=>row.cell.number==4 && row.label=="before",(int n)=>false));
}

private struct QualifiedArrays {const(int)[] readOnly;immutable(int)[] fixedValues;}
unittest {
    auto backing=[2,3];
    immutable(int)[] fixedValues=[4,5];
    auto reflected=Value.reflect(QualifiedArrays(backing,fixedValues));
    backing[0]=8;
    assert(reflected.tableValue["readOnly"].arrayValue[0].toInt()==2);
    assert(reflected.tableValue["fixedValues"].arrayValue[0].toInt()==4);
}
private struct ExternalRead {
    int* input;
    int captured;
    this(this) pure nothrow { if(input !is null) captured=*input; }
}
private struct ExternalReadField {ExternalRead row;}
unittest {
    int external=5;
    auto value=Value.reflect(ExternalReadField(ExternalRead(&external,0)));
    external=17;
    // copy constructorが外部可変メモリを読む型は、展開を遅延しません。
    assert(value.tableValue["row"].tableValue["captured"].toInt()==5);
    assert(value.propertyGetter("row").functionValue.invoke([]).tableValue["captured"].toInt()==17);
}

unittest {
    auto engine=new ScriptEngine;
    engine.bindAuto("data",FrozenFields(Row(Cell(3),"original"),[Row(Cell(5),"array")],[7]));
    engine.bindAuto("replacement",Row(Cell(40),"replacement"));
    engine.bindAuto("replacementRows",[Row(Cell(50),"new array")]);
    auto result=engine.run(q{
        auto original=data;
        auto seen=data.row;
        data.row=replacement;
        data.rows=replacementRows;
        if(data.row.cell.number!=40 || data.rows[0].cell.number!=50) return false;
        auto worker=coroutine.create((){
            auto local=data;
            local.row=original.row;
            yield local.row;
            local.row=replacement.painted(70);
            local.rows=original.rows;
            return local;
        });
        auto first=coroutine.resume(worker);
        auto last=coroutine.resume(worker);
        return first[0] && last[0] && first[1].cell.number==3
            && last[1].row.cell.number==70 && last[1].rows[0].cell.number==5
            && data.row.cell.number==40 && data.rows[0].cell.number==50
            && seen.cell.number==3 && original.row.cell.number==3;
    });
    assert(result.truthy());
}
