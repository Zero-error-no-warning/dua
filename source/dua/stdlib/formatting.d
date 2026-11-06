module dua.stdlib.formatting;
import dua.value;
alias Dua = dua.value;
string debugValue(const Dua.Value value,size_t depth=0){
    import std.conv : to;
    import std.string : join;
    if(value.kind==Dua.ValueKind.table || value.kind==Dua.ValueKind.struct_){
        if(depth>=2)return "{...}";
        string[] entries;
        foreach(key,item;value.tableValue){
            if(entries.length==12){entries~="...";break;}
            entries~=key~": "~debugValue(item,depth+1);
        }
        return "{"~entries.join(", ")~"}";
    }
    if(value.kind==Dua.ValueKind.array){
        if(depth>=2)return "[...]";
        string[] entries;
        foreach(item;value.arrayValue){if(entries.length==12){entries~="...";break;}entries~=debugValue(item,depth+1);}
        return "["~entries.join(", ")~"]";
    }
    if(value.kind==Dua.ValueKind.associativeArray)return "<associative array>";
    return value.toHostString();
}

string formatDua(string fmt, const(Dua.Value)[] args...){
            import std.array : appender;
            import std.format : FormatException, FormatSpec, formatValue;
            auto result=appender!string();
            auto spec=FormatSpec!char(fmt);
            size_t nextArg;
            while(spec.writeUpToNextSpec(result)){
                auto index=spec.indexStart ? spec.indexStart-1 : nextArg;
                if(index>=args.length)throw new FormatException("Not enough arguments for string.format");
                auto end=spec.indexEnd ? spec.indexEnd : index+1;
                if(end==uint.max)end=args.length;
                if(end>args.length)throw new FormatException("Not enough arguments for string.format");
                foreach(arg;args[index..end]){
                    // 数値の型を保ち、桁数や精度の指定を標準フォーマッタへ渡す。
                    switch(arg.kind){
                        case Dua.ValueKind.integer: formatValue(result,arg.integerValue,spec);break;
                        case Dua.ValueKind.floating: formatValue(result,arg.floatingValue,spec);break;
                        case Dua.ValueKind.boolean: formatValue(result,arg.booleanValue,spec);break;
                        case Dua.ValueKind.string_: formatValue(result,arg.stringValue,spec);break;
                        default: formatValue(result,debugValue(arg),spec);break;
                    }
                }
                if(nextArg<end)nextArg=end;
            }
            return result.data;
        }
