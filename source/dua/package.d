module dua;

public import dua.runtime;
public import dua.execution;
public import dua.value;

/// Namespaced facade for embedding APIs.
///
/// Usage:
/// ---
/// auto engine = new Dua.ScriptEngine();
/// engine.bind("answer", Dua.Value.from(42));
/// ---
struct Dua
{
    alias Value = dua.value.Value;
    alias ValueKind = dua.value.ValueKind;
    alias CallableValue = dua.value.CallableValue;
    alias ScriptEngine = dua.runtime.ScriptEngine;
    alias ScriptModule = dua.runtime.ScriptModule;
    alias ModuleHandle = dua.runtime.ModuleHandle;
    alias RunOutcome = dua.runtime.RunOutcome;
    alias RunErrorKind = dua.runtime.RunErrorKind;
    alias ExecutionLimits = dua.runtime.ExecutionLimits;
    alias RunOptions = dua.runtime.RunOptions;
    alias CheckDiagnostic = dua.runtime.CheckDiagnostic;
}
