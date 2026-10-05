module dua.native_defaults;

import std.ascii : isAlpha, isDigit, isWhite;

package(dua) enum LocationDefault { none, moduleName, sourceName, line }

// D's stringof format is compiler dependent. Accept only an assignment in a
// single parameter slice whose RHS is exactly one identifier token. Anything
// else (including literals, comments, casts and compound expressions) falls
// back to ParameterDefaults. No source text or evaluated values are searched.
// A compiler may erase redundant parentheses/casts before returning stringof;
// in that case the remaining bare macro is supported as well.
package(dua) LocationDefault detectLocationDefault(string syntax) pure
{
    int parentheses, brackets, braces;
    size_t index;
    while (index < syntax.length)
    {
        auto c = syntax[index++];
        if (isWhite(c)) continue;
        if (c == '"' || c == '\'' || c == '`' || c == '/')
            return LocationDefault.none;
        if (c == '(') ++parentheses;
        else if (c == ')') --parentheses;
        else if (c == '[') ++brackets;
        else if (c == ']') --brackets;
        else if (c == '{') ++braces;
        else if (c == '}') --braces;
        else if (c == '=' && parentheses == 1 && brackets == 0 && braces == 0)
        {
            while (index < syntax.length && isWhite(syntax[index])) ++index;
            auto start = index;
            if (index == syntax.length || !(isAlpha(syntax[index]) || syntax[index] == '_'))
                return LocationDefault.none;
            ++index;
            while (index < syntax.length && (isAlpha(syntax[index])
                || isDigit(syntax[index]) || syntax[index] == '_')) ++index;
            auto identifier = syntax[start .. index];
            while (index < syntax.length && isWhite(syntax[index])) ++index;
            if (index == syntax.length || syntax[index++] != ')') return LocationDefault.none;
            while (index < syntax.length && isWhite(syntax[index])) ++index;
            if (index != syntax.length) return LocationDefault.none;
            switch (identifier)
            {
                case "__MODULE__": return LocationDefault.moduleName;
                case "__FILE__": return LocationDefault.sourceName;
                case "__LINE__": return LocationDefault.line;
                default: return LocationDefault.none;
            }
        }
    }
    return LocationDefault.none;
}

package(dua) template parameterLocationDefault(alias declaration, size_t index)
{
    static if (is(typeof(declaration) P == __parameters))
        enum parameterLocationDefault = detectLocationDefault(P[index .. index + 1].stringof);
    else static if (is(declaration P == __parameters))
        enum parameterLocationDefault = detectLocationDefault(P[index .. index + 1].stringof);
    else
        enum parameterLocationDefault = LocationDefault.none;
}

unittest
{
    assert(detectLocationDefault("(string arbitrary = __MODULE__)") == LocationDefault.moduleName);
    assert(detectLocationDefault("(string arbitrary = __FILE__)") == LocationDefault.sourceName);
    assert(detectLocationDefault("(int arbitrary = __LINE__)") == LocationDefault.line);
    foreach (syntax; [
        `(string M = "__MODULE__")`, `(string F = r"__FILE__")`,
        "(int L = 42)", "(int L = __LINE__ + 1)", "(int L = (__LINE__))",
        `(string M = __MODULE__ ~ "suffix")`, "(int L = cast(int)__LINE__)",
        "(int L = __LINE__suffix)", "(int L = /* __LINE__ */ 42)",
        "(void delegate(string M = __MODULE__) cb)", `(string M = q{__MODULE__})`])
        assert(detectLocationDefault(syntax) == LocationDefault.none, syntax);
}
