module dua.execution;

import dua.value : Value;

/// Categorizes failures returned by the non-throwing execution API.
enum RunErrorKind
{
    none,
    runtime,
    stepLimit,
    callDepthLimit
}

/// Script positions are 1-based UTF-8 byte columns; zero means unknown.
struct ScriptDiagnostic
{
    string sourceName;
    size_t line;
    size_t column;
    string message;
    string sourceText;
    bool hasSourceText;
}

/// Extracts only interpreter-owned structured data, never parses message text.
ScriptDiagnostic scriptDiagnostic(Throwable error)
{
    auto message = error is null ? "" : error.msg;
    for(auto cause=error; cause !is null; cause=cause.next)
        if(auto sourced=cast(SourceException)cause)return sourced.diagnostic;
    ScriptDiagnostic result; result.message=message; return result;
}

package Exception locatedException(string message, size_t line, size_t column)
{
    auto error=new SourceException(message);
    error.diagnostic.line=line; error.diagnostic.column=column;
    return error;
}

package Exception withDiagnosticSource(Exception error,string sourceName,string sourceText)
{
    if(auto sourced=cast(SourceException)error)
        if(sourced.diagnostic.sourceName==sourceName && !sourced.diagnostic.hasSourceText){
            sourced.diagnostic.sourceText=sourceText;sourced.diagnostic.hasSourceText=true;
        }
    return error;
}

package Exception outcomeException(RunOutcome outcome, string message)
{
    auto error=new SourceException(message);
    error.diagnostic=outcome.diagnostic;
    error.hasSourceContext=true;
    return error;
}

/// Internal marker preserving the first diagnostic origin during propagation.
package class SourceException : Exception
{
    bool hasSourceContext;
    ScriptDiagnostic diagnostic;

    this(string message, Throwable next = null)
    {
        super(message, __FILE__, __LINE__, next);
        diagnostic.message=message;
    }
}

/// Base class for limits enforced by the interpreter rather than script errors.
class ExecutionLimitException : SourceException
{
    this(string message)
    {
        super(message);
    }
}

final class StepLimitException : ExecutionLimitException
{
    this(size_t maximum)
    {
        import std.format : format;
        // Keep the diagnostic stable for embedders while classification uses
        // this exception's type rather than inspecting the text.
        super(format("[limit:steps] Execution step limit exceeded (%s)", maximum));
    }
}

final class CallDepthLimitException : ExecutionLimitException
{
    this(size_t maximum)
    {
        import std.format : format;
        super(format("[limit:call-depth] Function call depth limit exceeded (%s)", maximum));
    }
}

struct ExecutionLimits
{
    /// Zero means unlimited.
    size_t maxSteps;
    /// Zero means unlimited.
    size_t maxCallDepth;
}

struct RunOptions
{
    ExecutionLimits limits;
    bool typeCheck;
    /// Diagnostic name for source strings. File APIs use their path instead.
    string sourceName;
}

struct RunOutcome
{
    bool ok;
    Value value;
    string errorMessage;
    string[] stackTrace;
    RunErrorKind errorKind;
    size_t stepsExecuted;
    ScriptDiagnostic diagnostic;
}

struct CheckDiagnostic
{
    size_t line;
    size_t column;
    string message;
    string sourceName;
    string sourceText;
}
