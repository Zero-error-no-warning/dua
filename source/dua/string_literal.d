module dua.string_literal;

import dua.execution : locatedException;
import std.array : appender;
import std.ascii : isAlpha, isAlphaNum;

// 生の位置を維持したまま走査し、文字部分だけを後から復号する。
void advanceStringPosition(string source, ref size_t cursor, ref size_t line, ref size_t column)
{
    if (source[cursor++] == '\n') { ++line; column = 1; }
    else ++column;
}

char readStringEscape(string source, ref size_t cursor, size_t line, size_t column)
{
    auto start = cursor++;
    if (cursor >= source.length)
        throw locatedException("Unterminated string escape", line, column);
    switch (source[cursor++])
    {
        case 'n': return '\n';
        case 'r': return '\r';
        case 't': return '\t';
        case '0': return '\0';
        case '"': return '"';
        case '\\': return '\\';
        default: throw locatedException("Invalid string escape: " ~ source[start .. cursor], line, column);
    }
}

string decodeStringLiteral(string source, size_t line, size_t column)
{
    auto result = appender!string();
    size_t cursor;
    while (cursor < source.length)
    {
        if (source[cursor] == '\\')
        {
            result.put(readStringEscape(source, cursor, line, column));
            column += 2;
        }
        else
        {
            result.put(source[cursor]);
            advanceStringPosition(source, cursor, line, column);
        }
    }
    return result.data;
}

// cursor は開始引用符を指す。終了時は終了引用符の次を指す。
string scanStringLiteral(string source, ref size_t cursor, ref size_t line,
    ref size_t column, bool interpolated)
{
    auto startLine = line, startColumn = column;
    advanceStringPosition(source, cursor, line, column);
    auto start = cursor;
    while (cursor < source.length)
    {
        auto ch = source[cursor];
        if (ch == '"')
        {
            auto raw = source[start .. cursor];
            advanceStringPosition(source, cursor, line, column);
            return raw;
        }
        if (ch == '\n' || ch == '\r') break;
        if (ch == '\\')
        {
            readStringEscape(source, cursor, line, column);
            column += 2;
            continue;
        }
        if (interpolated && ch == '$' && cursor + 1 < source.length)
        {
            if (source[cursor + 1] == '$') { cursor += 2; column += 2; continue; }
            if (source[cursor + 1] == '(')
            {
                cursor += 2; column += 2;
                scanInterpolationEnd(source, cursor, line, column);
            }
        }
        advanceStringPosition(source, cursor, line, column);
    }
    throw locatedException("Unterminated string", startLine, startColumn);
}

// コメント、通常文字列、入れ子補間の括弧を外側の括弧と混同しない。
// cursor は式の先頭から対応する ')' まで進む（')' 自体は消費しない）。
void scanInterpolationEnd(string source, ref size_t cursor, ref size_t line, ref size_t column)
{
    auto startLine = line, startColumn = column;
    size_t depth = 1;
    bool prefix;
    while (cursor < source.length)
    {
        auto ch = source[cursor];
        auto next = cursor + 1 < source.length ? source[cursor + 1] : '\0';
        if (ch == '#' || (ch == '/' && next == '/'))
        {
            while (cursor < source.length && source[cursor] != '\n')
                advanceStringPosition(source, cursor, line, column);
            continue;
        }
        if (ch == '/' && next == '+')
        {
            auto commentLine = line, commentColumn = column;
            size_t nesting = 1;
            cursor += 2; column += 2;
            while (cursor < source.length && nesting)
            {
                auto pair = source[cursor .. (cursor + 2 < source.length ? cursor + 2 : source.length)];
                if (pair == "/+") { ++nesting; cursor += 2; column += 2; }
                else if (pair == "+/") { --nesting; cursor += 2; column += 2; }
                else advanceStringPosition(source, cursor, line, column);
            }
            if (nesting) throw locatedException("Unterminated block comment", commentLine, commentColumn);
            continue;
        }
        if (ch == '"')
        {
            scanStringLiteral(source, cursor, line, column, prefix);
            prefix = false;
            continue;
        }
        if (isAlpha(ch) || ch == '_')
        {
            auto start = cursor;
            do { advanceStringPosition(source, cursor, line, column); }
            while (cursor < source.length && (isAlphaNum(source[cursor]) || source[cursor] == '_'));
            prefix = source[start .. cursor] == "i";
            continue;
        }
        if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') prefix = false;
        if (ch == '(') ++depth;
        if (ch == ')' && --depth == 0) return;
        advanceStringPosition(source, cursor, line, column);
    }
    throw locatedException("Unterminated interpolation sequence", startLine, startColumn);
}
