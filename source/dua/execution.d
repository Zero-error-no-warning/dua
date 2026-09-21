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

/// Internal marker preserving the first diagnostic origin during propagation.
package class SourceException : Exception
{
    bool hasSourceContext;

    this(string message, Throwable next = null)
    {
        super(message, __FILE__, __LINE__, next);
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
}

struct CheckDiagnostic
{
    size_t line;
    size_t column;
    string message;
}
