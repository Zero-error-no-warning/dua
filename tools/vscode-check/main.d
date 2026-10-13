module vscode_check;

import dua : Dua;
import std.array : join;
import std.json : JSONValue;
import std.stdio : stdin, writeln;

// A single request on stdin, a JSON response on stdout. Never executes scripts,
// resolves imports, or reads files named by a script.
void main()
{
    auto bytes = stdin.byChunk(4096).join;
    auto engine = new Dua.ScriptEngine();
    JSONValue[] diagnostics;
    foreach (diagnostic; engine.check(cast(string) bytes))
    {
        JSONValue[string] item;
        item["line"] = JSONValue(cast(ulong) diagnostic.line);
        item["column"] = JSONValue(cast(ulong) diagnostic.column);
        item["message"] = JSONValue(diagnostic.message);
        diagnostics ~= JSONValue(item);
    }
    JSONValue[string] response;
    response["diagnostics"] = JSONValue(diagnostics);
    writeln(JSONValue(response).toString());
}
