module vscode_check;

import dua;
import dua.module_analysis;
import std.array : join;
import std.exception : enforce;
import std.json : JSONValue, JSONType, parseJSON;
import std.stdio : stdin, writeln;
import std.string : stripLeft;

private JSONValue text(string value) { return JSONValue(value); }
private JSONValue position(size_t value) { return JSONValue(cast(ulong)value); }
private string field(JSONValue value, string name, string fallback = "")
{
    enforce(value.type == JSONType.object, "Expected an object containing field '" ~ name ~ "'");
    auto found = name in value.object;
    if (found is null) return fallback;
    enforce(found.type == JSONType.string, "Field '" ~ name ~ "' must be a string");
    return found.str;
}
private JSONValue[] arrayItems(JSONValue value, string name)
{
    enforce(value.type == JSONType.array, "Field '" ~ name ~ "' must be an array");
    return value.array;
}
private string[] stringItems(JSONValue value, string name)
{
    string[] result;
    foreach (item; arrayItems(value, name))
    {
        enforce(item.type == JSONType.string, "Field '" ~ name ~ "' must contain strings");
        result ~= item.str;
    }
    return result;
}
private bool booleanValue(JSONValue value, string name)
{
    enforce(value.type == JSONType.true_ || value.type == JSONType.false_,
        "Field '" ~ name ~ "' must be a boolean");
    return value.boolean;
}
private JSONValue strings(string[] values)
{
    JSONValue[] result;
    foreach (value; values) result ~= text(value);
    return JSONValue(result);
}

private JSONValue describeExport(ModuleExportInfo value)
{
    JSONValue[] lazyParameters;
    foreach(flag;value.parameterLazy)lazyParameters~=JSONValue(flag);
    JSONValue[string] fields;
    foreach (name, type; value.fields) fields[name] = text(type);
    return JSONValue([
        "name": text(value.name), "kind": text(value.kind), "type": text(value.type),
        "displayType": text(value.displayType), "runtimeValue": JSONValue(value.runtimeValue),
        "exported": JSONValue(value.exported), "declarationKind": text(value.declarationKind),
        "fields": JSONValue(fields), "defaultFields": strings(value.defaultFields), "fieldOrder": strings(value.fieldOrder),
        "alternatives": strings(value.alternatives), "parameterTypes": strings(value.parameterTypes),
        "parameterLazy": JSONValue(lazyParameters),
        "parameterNames": strings(value.parameterNames),
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
    string sourceName;
    try
    {
        ModuleContext context;
        string[] hostClassTypes;
        string[string] overlays;
        if (structured)
        {
            source = field(request, "source");
            sourceName = field(request, "sourceName");
            if (auto paths = "modulePaths" in request.object)
            {
                engine.setModulePaths(stringItems(*paths, "modulePaths"));
            }
            if (auto types = "hostClassTypes" in request.object)
                hostClassTypes = stringItems(*types, "hostClassTypes");
            if (auto hosts = "hostModules" in request.object)
                foreach (host; arrayItems(*hosts, "hostModules"))
                {
                    enforce(host.type == JSONType.object, "Field 'hostModules' must contain objects");
                    ModuleExportInfo[] members;
                    if (auto values = "exports" in host.object)
                        foreach (value; arrayItems(*values, "exports"))
                        {
                            ModuleExportInfo info;
                            info.name = field(value, "name"); info.kind = field(value, "kind", "variable");
                            info.type = field(value, "type", "any");
                            info.runtimeValue = info.kind == "type";
                            if (auto runtimeValue = "runtimeValue" in value.object) info.runtimeValue = booleanValue(*runtimeValue, "runtimeValue");
                            if (auto variadic = "variadic" in value.object) info.variadic = booleanValue(*variadic, "variadic");
                            if (auto parameters = "parameterTypes" in value.object)
                                info.parameterTypes = stringItems(*parameters, "parameterTypes");
                            if (auto parameters = "parameterLazy" in value.object)
                                foreach (parameter; arrayItems(*parameters, "parameterLazy")) info.parameterLazy ~= booleanValue(parameter, "parameterLazy");
                            members ~= info;
                        }
                    auto complete = "exportsComplete" in host.object;
                    engine.declareAnalysisModule(field(host, "name"), members, complete !is null && booleanValue(*complete, "exportsComplete"));
                }
            if (auto values = "overlays" in request.object)
                foreach (overlay; arrayItems(*values, "overlays")) overlays[field(overlay, "sourceName")] = field(overlay, "source");
        }
        if(structured)if(auto boundary = "sourceBoundary" in request.object){
            import dua.module_resolver : validateModuleSourceBoundary;
            auto root = field(*boundary, "root");
            auto marker = field(*boundary, "markerExtension");
            import std.path : isAbsolute;
            import std.exception : enforce;
            enforce(isAbsolute(root), "Source boundary root must be absolute");
            context=engine.createModuleContext();
            context.validateSource=(string path){validateModuleSourceBoundary(root,path,marker);};
        }
        auto analysis = engine.analyzeModule(source, sourceName, hostClassTypes, overlays, context);
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
            foreach (candidate; engine.importPathCompletions(field(request, "importPathPrefix"), sourceName, overlays, context))
                completions ~= JSONValue([
                    "label": text(candidate.label), "sourceName": text(candidate.sourceName),
                    "key": text(candidate.key), "directory": JSONValue(candidate.directory)]);
    }
    catch (Exception error)
    {
        diagnostics ~= JSONValue(["line": position(0), "column": position(0), "message": text(error.msg),
            "sourceName": text(sourceName), "sourceText": text(source)]);
    }
    writeln(JSONValue([
        "schemaVersion": JSONValue(1), "diagnostics": JSONValue(diagnostics), "modules": JSONValue(modules),
        "imports": JSONValue(imports), "exports": JSONValue(exports), "pathCompletions": JSONValue(completions)]).toString());
}
