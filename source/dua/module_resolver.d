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

ImportPathCompletion[] completeImportPaths(string prefix, string importer, string[string] overlays = null,
    void delegate(string) validateSource = null)
{
    import std.string : lastIndexOf;
    version (Windows) prefix = prefix.replace("\\", "/");
    auto slash = prefix.lastIndexOf('/');
    auto prefixDirectory = slash < 0 ? "" : prefix[0 .. slash + 1];
    auto partial = slash < 0 ? prefix : prefix[slash + 1 .. $];
    auto directory = resolveFileImport(prefixDirectory.length ? prefixDirectory : ".", importer, true, null).candidates[0];
    ImportPathCompletion[] result;
    if(validateSource !is null)try{validateSource(directory);}catch(Exception){return result;}
    bool[string] seen;
    void add(string path, bool folder)
    {
        if(validateSource !is null)try{validateSource(path);}catch(Exception){return;}
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

/// ホストが明示したrootと子projectの境界を、実行・解析で共用します。
void validateModuleSourceBoundary(string root, string source, string markerExtension = "")
{
    import std.path : relativePath;
    import std.file : isSymlink;
    auto base = canonicalModulePath(root);
    auto resolved = canonicalModulePath(source);
    auto relative = relativePath(resolved, base);
    enforce(!isAbsolute(relative) && relative != ".." && !relative.startsWith("../") && !relative.startsWith("..\\"),
        "Reference escapes project: " ~ source);
    for(auto current = resolved; current != base; current = current.dirName) {
        enforce(current != current.dirName, "Invalid project reference: " ~ source);
        version (Windows) validateBoundaryComponent(current, markerExtension);
        else
        {
            enforce(!exists(current) || !isSymlink(current), "Project reference crosses a link: " ~ current);
            if(markerExtension.length && exists(current) && isDir(current))
                foreach(entry; dirEntries(current, SpanMode.shallow))
                    enforce(entry.isDir || entry.name.extension.toLower != markerExtension.toLower,
                        "Reference crosses another project: " ~ current);
        }
    }
}

// Windowsでは属性を一度取得し、marker候補だけを列挙します。結果は呼出しを越えて保持しません。
version (Windows) private bool containsProjectMarker(string directory, string markerExtension)
{
    import core.sys.windows.windows;
    import std.file : FileException;
    import std.conv : to;
    import std.utf : toUTF16z;
    bool simple = markerExtension.length > 1 && markerExtension[0] == '.';
    foreach (c; markerExtension)
        simple = simple && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-');
    // 任意のextension引数にWindowsのglobやパスの意味を与えません。
    if (!simple)
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow))
            if (!entry.isDir && entry.name.extension.toLower == markerExtension.toLower) return true;
        return false;
    }
    WIN32_FIND_DATAW data;
    auto handle = FindFirstFileW(buildPath(directory, "*" ~ markerExtension).toUTF16z, &data);
    if (handle == INVALID_HANDLE_VALUE)
    {
        auto error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) return false;
        throw new FileException(directory, error);
    }
    scope(exit) FindClose(handle);
    do
    {
        if (!(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
        {
            auto name = to!string(data.cFileName.ptr);
            // Win32の短縮名や拡張子パターンによる余分な一致を除外します。
            if (name.extension.toLower == markerExtension.toLower) return true;
        }
    } while (FindNextFileW(handle, &data));
    auto error = GetLastError();
    if (error != ERROR_NO_MORE_FILES) throw new FileException(directory, error);
    return false;
}

version (Windows) private void validateBoundaryComponent(string current, string markerExtension)
{
    import core.sys.windows.windows;
    import std.file : FileException;
    import std.utf : toUTF16z;
    auto attributes = GetFileAttributesW(current.toUTF16z);
    if (attributes == INVALID_FILE_ATTRIBUTES)
    {
        auto error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
        throw new FileException(current, error);
    }
    enforce(!(attributes & FILE_ATTRIBUTE_REPARSE_POINT), "Project reference crosses a link: " ~ current);
    if (markerExtension.length && (attributes & FILE_ATTRIBUTE_DIRECTORY))
        enforce(!containsProjectMarker(current, markerExtension), "Reference crosses another project: " ~ current);
}


unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write, remove, rmdir;
    import std.uuid : randomUUID;
    import std.exception : assertThrown;
    auto root = buildPath(tempDir, "dua-boundary-refresh-" ~ randomUUID().toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto child = buildPath(root, "child"), leaf = buildPath(child, "assets", "image.png");
    mkdirRecurse(leaf.dirName);
    write(buildPath(root, "root.zproject"), "{}");
    validateModuleSourceBoundary(root, leaf, ".zproject"); // 未作成resourceも許容します。
    write(leaf, "first");
    validateModuleSourceBoundary(root, leaf, ".zproject");
    write(leaf, "updated");
    validateModuleSourceBoundary(root, leaf, ".zproject");
    auto marker = buildPath(child, "nested.ZPROJECT");
    write(marker, "{}");
    assertThrown!Exception(validateModuleSourceBoundary(root, leaf, ".zproject"));
    remove(marker);
    validateModuleSourceBoundary(root, leaf, ".zproject");
    mkdirRecurse(marker); // 同じ拡張子のdirectoryはproject markerではありません。
    validateModuleSourceBoundary(root, leaf, ".zproject");
    rmdir(marker);
    auto backup = buildPath(child, "nested.zproject.bak");
    write(backup, "{}");
    validateModuleSourceBoundary(root, leaf, ".zproject");
    write(marker, "{}");
    assertThrown!Exception(validateModuleSourceBoundary(root, leaf, ".ZPROJECT"));
    remove(marker);
    validateModuleSourceBoundary(root, root, ".zproject");
    assertThrown!Exception(validateModuleSourceBoundary(child, buildPath(root, "sibling", "image.png"), ".zproject"));
    assertThrown!Exception(validateModuleSourceBoundary(root, buildPath(root, "..", "outside.png"), ".zproject"));
}


version (Windows) unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.uuid : randomUUID;
    auto root = buildPath(tempDir, "dua-completion-separators-" ~ randomUUID().toString);
    mkdirRecurse(buildPath(root, "sub"));
    scope(exit) rmdirRecurse(root);
    write(buildPath(root, "sub", "module.dua"), "return 1;");
    auto importer = buildPath(root, "main.dua");
    string[string] overlays;
    overlays[buildPath(root, "sub", "missing.dua")] = "return 2;";
    foreach (prefix; ["sub/m", "sub\\m", "sub\\", "sub/"])
    {
        auto candidates = completeImportPaths(prefix, importer, overlays);
        assert(candidates.length == 2, prefix);
        assert(candidates[0].label == "sub/missing.dua", candidates[0].label);
        assert(candidates[1].label == "sub/module.dua", candidates[1].label);
    }
    size_t validated;
    auto candidates = completeImportPaths("sub\\m", importer, overlays, (string path) {
        ++validated;
        validateModuleSourceBoundary(root, path);
        enforce(!path.canFind("missing.dua"), "Filtered overlay");
    });
    assert(candidates.length == 1 && candidates[0].label == "sub/module.dua");
    assert(validated >= 3);
}
