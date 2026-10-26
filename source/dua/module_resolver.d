module dua.module_resolver;

import std.algorithm : canFind;
import std.exception : enforce;
import std.file : exists, isFile, isDir, dirEntries, SpanMode;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, isAbsolute, baseName, extension;
import std.string : replace, startsWith, toLower;

/// Shared, side-effect-free import result for runtime and editor tooling.
struct ImportResolution
{
    string request;
    string importer;
    string key;
    string sourceName;
    string[] candidates;
    bool registered;
    bool pathImport;
}

string canonicalModulePath(string path)
{
    auto result = absolutePath(path).buildNormalizedPath;
    version (Windows) result = result.toLower();
    return result;
}

/// Registered module lookup is supplied by the engine, not filesystem search.
ImportResolution resolveFileImport(string request, string importer, bool pathImport,
    string[] searchPaths, bool delegate(string) overlayExists = null)
{
    ImportResolution result;
    result.request = request;
    result.importer = importer;
    result.pathImport = pathImport;
    if (pathImport)
    {
        enforce(importer.length && importer[0] != '<' && (isAbsolute(importer) || importer.extension == ".dua"),
            "Relative import '" ~ request ~ "' requires the saved source path (sourceName)");
        auto path = isAbsolute(request) ? request : buildPath(absolutePath(importer).dirName, request);
        result.candidates ~= canonicalModulePath(path);
    }
    else
    {
        auto modulePath = request.replace(".", "/");
        foreach (pattern; searchPaths)
            result.candidates ~= canonicalModulePath(pattern.replace("?", modulePath));
    }
    foreach (candidate; result.candidates)
        if ((overlayExists !is null && overlayExists(candidate)) || (exists(candidate) && isFile(candidate)))
        {
            result.key = candidate;
            result.sourceName = candidate;
            return result;
        }
    return result;
}

struct ImportPathCompletion
{
    string label, sourceName, key;
    bool directory;
}

ImportPathCompletion[] completeImportPaths(string prefix, string importer, string[string] overlays = null)
{
    import std.string : lastIndexOf;
    auto slash = prefix.lastIndexOf('/');
    auto prefixDirectory = slash < 0 ? "" : prefix[0 .. slash + 1];
    auto partial = slash < 0 ? prefix : prefix[slash + 1 .. $];
    auto directory = resolveFileImport(prefixDirectory.length ? prefixDirectory : ".", importer, true, null).candidates[0];
    ImportPathCompletion[] result;
    bool[string] seen;
    void add(string path, bool folder)
    {
        auto name = path.baseName;
        if (!name.startsWith(partial) || (!folder && path.extension.toLower() != ".dua")) return;
        auto key = canonicalModulePath(path);
        if ((key in seen) !is null) return;
        seen[key] = true;
        result ~= ImportPathCompletion(prefixDirectory ~ name ~ (folder ? "/" : ""), path, key, folder);
    }
    if (exists(directory) && isDir(directory))
        foreach (entry; dirEntries(directory, SpanMode.shallow)) add(entry.name, entry.isDir);
    foreach (path; overlays.byKey)
        if (canonicalModulePath(path).dirName == directory) add(path, false);
    import std.algorithm : sort;
    result.sort!((a, b) => a.label < b.label);
    return result;
}

string unresolvedImportMessage(ImportResolution result)
{
    import std.string : join;
    return "Cannot resolve import '" ~ result.request ~ "' from '"
        ~ (result.importer.length ? result.importer : "<unsaved source>")
        ~ "'. Tried: " ~ (result.candidates.length ? result.candidates.join(", ") : "<no search paths>");
}
