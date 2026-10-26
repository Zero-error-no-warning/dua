module dua.type_syntax;

import std.json : JSONValue;

// 一般の交差型ではなく、null だけを除外する限定 wrapper です。
package(dua) string nonNullType(string inner) { return "(" ~ inner ~ " & !null)"; }

package(dua) bool splitNonNullType(string name, out string inner)
{
    enum suffix = " & !null)";
    if (name.length <= suffix.length + 1 || name[0] != '('
        || name[$ - suffix.length .. $] != suffix) return false;
    size_t depth;
    bool quoted, escaped;
    foreach (i, ch; name)
    {
        if (quoted)
        {
            if (escaped) escaped = false;
            else if (ch == '\\') escaped = true;
            else if (ch == '"') quoted = false;
            continue;
        }
        if (ch == '"') { quoted = true; continue; }
        if (ch == '(') ++depth;
        else if (ch == ')' && --depth == 0 && i + 1 != name.length) return false;
    }
    if (depth) return false;
    inner = name[1 .. $ - suffix.length];
    return true;
}

// 型名と文字列の値を混同しないよう、リテラル型はJSONの引用表記で保持します。
package(dua) string stringLiteralType(string value)
{
    return JSONValue(value).toString();
}

package(dua) bool isStringLiteralType(string name)
{
    if (name.length < 2 || name[0] != '"') return false;
    for (size_t i = 1; i < name.length; ++i)
    {
        if (name[i] == '\\') ++i;
        else if (name[i] == '"') return i == name.length - 1;
    }
    return false;
}

// ホストの公開名と衝突しても、組込み型の規則を優先します。
package(dua) bool isBuiltinTypeName(string name)
{
    switch (name)
    {
        case "auto", "any", "void", "null", "bool",
             "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
             "float", "double", "real", "string", "array", "table",
             "associativeArray", "function": return true;
        default: return false;
    }
}

/// Split the outermost V[K] (or V[]) suffix, preserving nested type names.
package(dua) bool splitContainerType(string name, out string element, out string key)
{
    if (name.length == 0 || name[$ - 1] != ']') return false;
    size_t depth, start, parentheses;
    bool quoted;
    foreach (index, ch; name)
    {
        if (quoted)
        {
            // JSON表記のバックスラッシュが直前に奇数個なら引用符は閉じません。
            if (ch == '"')
            {
                size_t backslashes, previous = index;
                while (previous > 0 && name[--previous] == '\\') ++backslashes;
                if (backslashes % 2 == 0) quoted = false;
            }
            continue;
        }
        if (ch == '"') quoted = true;
        else if (ch == '(') ++parentheses;
        else if (ch == ')' && parentheses) --parentheses;
        else if (ch == '[' && !parentheses) { if (depth++ == 0) start = index; }
        else if (ch == ']' && !parentheses && depth && --depth == 0 && index == name.length - 1)
        {
            if (start == 0) return false;
            element = name[0 .. start];
            key = name[start + 1 .. index];
            return true;
        }
    }
    return false;
}
