module vscode_check;

import dua;
import dua.module_analysis;
import std.array : join;
import std.json : JSONValue, JSONType, parseJSON;
import std.stdio : stdin, writeln;
import std.string : stripLeft;

private JSONValue text(string value) { return JSONValue(value); }
private JSONValue position(size_t value) { return JSONValue(cast(ulong)value); }
private string field(JSONValue value, string name, string fallback = "")
{
    auto found = name in value.object;
    return found !is null && found.type == JSONType.string ? found.str : fallback;
}
private JSONValue strings(string[] values)
{
    JSONValue[] result;
    foreach (value; values) result ~= text(value);
    return JSONValue(result);
}

private JSONValue describeExport(ModuleExportInfo value)
{
    JSONValue[string] fields;
    foreach (name, type; value.fields) fields[name] = text(type);
    return JSONValue([
        "name": text(value.name), "kind": text(value.kind), "type": text(value.type),
        "displayType": text(value.displayType), "runtimeValue": JSONValue(value.runtimeValue),
        "exported": JSONValue(value.exported), "declarationKind": text(value.declarationKind),
        "fields": JSONValue(fields), "alternatives": strings(value.alternatives), "parameterTypes": strings(value.parameterTypes),
        "variadic": JSONValue(value.variadic),
        "requiredParameterCount": value.requiredParameterCount==size_t.max ? JSONValue(null) : position(value.requiredParameterCount),
        "nominalValue": JSONValue(value.nominalValue),
        "baseTypes": strings(value.baseTypes),
        "sourceName": text(value.sourceName), "line": position(value.line), "column": position(value.column)]);
}

void main()
{
    auto input = cast(string)stdin.byChunk(4096).join;
    auto source = input;
    JSONValue request;
    bool structured;
    if (input.stripLeft.length && input.stripLeft[0] == '{')
        try
        {
            request = parseJSON(input);
            structured = request.type == JSONType.object && ("source" in request.object) !is null;
        }
        catch (Exception) {}
    auto engine = new ScriptEngine;
    JSONValue[] diagnostics, modules, imports, exports, completions;
    try
    {
        string sourceName;
        string[] hostClassTypes;
        string[string] overlays;
        if (structured)
        {
            source = field(request, "source");
            sourceName = field(request, "sourceName");
            if (auto paths = "modulePaths" in request.object)
            {
                string[] values;
                foreach (path; paths.array) values ~= path.str;
                engine.setModulePaths(values);
            }
            if (auto types = "hostClassTypes" in request.object)
                foreach (type; types.array) hostClassTypes ~= type.str;
            if (auto hosts = "hostModules" in request.object)
                foreach (host; hosts.array)
                {
                    ModuleExportInfo[] members;
                    if (auto values = "exports" in host.object)
                        foreach (value; values.array)
                        {
                            ModuleExportInfo info;
                            info.name = field(value, "name"); info.kind = field(value, "kind", "variable");
                            info.type = field(value, "type", "any");
                            info.runtimeValue = info.kind == "type";
                            if (auto runtimeValue = "runtimeValue" in value.object) info.runtimeValue = runtimeValue.boolean;
                            if (auto variadic = "variadic" in value.object) info.variadic = variadic.boolean;
                            if (auto parameters = "parameterTypes" in value.object)
                                foreach (parameter; parameters.array) info.parameterTypes ~= parameter.str;
                            members ~= info;
                        }
                    auto complete = "exportsComplete" in host.object;
                    engine.declareAnalysisModule(field(host, "name"), members, complete !is null && complete.boolean);
                }
            if (auto values = "overlays" in request.object)
                foreach (overlay; values.array) overlays[field(overlay, "sourceName")] = field(overlay, "source");
        }
        auto analysis = engine.analyzeModule(source, sourceName, hostClassTypes, overlays);
        foreach (diagnostic; analysis.diagnostics)
            diagnostics ~= JSONValue([
                "line": position(diagnostic.line), "column": position(diagnostic.column),
                "sourceName": text(diagnostic.sourceName), "sourceText": text(diagnostic.sourceText),
                "message": text(diagnostic.message)]);
        foreach (unit; analysis.modules)
        {
            JSONValue[] unitImports, unitExports, unitTypes, constructions;
            foreach (construction; unit.typeConstructions)
                constructions ~= JSONValue([
                    "type":text(construction.type), "displayType":text(construction.displayType),
                    "sourceName":text(construction.sourceName), "line":position(construction.line),
                    "column":position(construction.column), "endLine":position(construction.endLine),
                    "endColumn":position(construction.endColumn)]);
            foreach (import_; unit.imports)
                unitImports ~= JSONValue([
                    "request": text(import_.request), "aliasName": text(import_.aliasName),
                    "pathImport": JSONValue(import_.pathImport), "key": text(import_.key),
                    "sourceName": text(import_.sourceName), "importer": text(unit.sourceName),
                    "line": position(import_.line), "column": position(import_.column)]);
            foreach (export_; unit.exports)
                unitExports ~= describeExport(export_);
            foreach (type; unit.types) unitTypes ~= describeExport(type);
            modules ~= JSONValue([
                "key": text(unit.key), "sourceName": text(unit.sourceName), "sourceText": text(unit.source),
                "dynamicExports": JSONValue(unit.dynamicExports),
                "exportsComplete": JSONValue(unit.exportsComplete),
                "imports": JSONValue(unitImports), "exports": JSONValue(unitExports), "types": JSONValue(unitTypes),
                "typeConstructions": JSONValue(constructions)]);
            if (unit is analysis.root) { imports = unitImports; exports = unitExports; }
        }
        if (structured && ("importPathPrefix" in request.object) !is null)
            foreach (candidate; engine.importPathCompletions(field(request, "importPathPrefix"), sourceName, overlays))
                completions ~= JSONValue([
                    "label": text(candidate.label), "sourceName": text(candidate.sourceName),
                    "key": text(candidate.key), "directory": JSONValue(candidate.directory)]);
    }
    catch (Exception error)
    {
        diagnostics ~= JSONValue(["line": position(0), "column": position(0), "message": text(error.msg),
            "sourceName": text(structured ? field(request, "sourceName") : ""), "sourceText": text(source)]);
    }
    writeln(JSONValue([
        "schemaVersion": JSONValue(1), "diagnostics": JSONValue(diagnostics), "modules": JSONValue(modules),
        "imports": JSONValue(imports), "exports": JSONValue(exports), "pathCompletions": JSONValue(completions)]).toString());
}
