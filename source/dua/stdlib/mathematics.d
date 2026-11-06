module dua.stdlib.mathematics;
import dua.value;
import dua.runtime : ModuleHandle;
import std.math;
import std.algorithm : clamp;

private double expValue(double x){return exp(x);}
private double fmodValue(double x,double y){return fmod(x,y);}
private double fmaxValue(double x,double y){return fmax(x,y);}
private double fminValue(double x,double y){return fmin(x,y);}
private double sqrtValue(double x){return sqrt(x);}
private double logValue(double x){return log(x);}
private double sinValue(double x){return sin(x);}
private double cosValue(double x){return cos(x);}
private double tanValue(double x){return tan(x);}
private double clampValue(double x,double low,double high){return clamp(x,low,high);}

package(dua) Value[string] extendedMathFunctions(){
    Value[string] result;
    result["PI"]=Value.fromAuto(PI);
    static foreach(pair;[
        ["exp","expValue"],["fmod","fmodValue"],["fmax","fmaxValue"],["fmin","fminValue"],
        ["sqrt","sqrtValue"],["log","logValue"],["sin","sinValue"],["cos","cosValue"],
        ["tan","tanValue"],["clamp","clampValue"]])
        result[pair[0]]=Value.fromFunction(makeReflectedCallable("math."~pair[0], &mixin(pair[1])));
    return result;
}



// Retain the typed binding metadata previously provided by ZsD.
package(dua) void installMathematicsModule(ModuleHandle handle, bool algorithmOnly=false){
    import dua.runtime : ModuleHandle;
    if(algorithmOnly){handle.bindFunc!clampValue("clamp");return;}
    handle.bindAuto("PI",PI);
    static foreach(pair;[
        ["exp","expValue"],["fmod","fmodValue"],["fmax","fmaxValue"],["fmin","fminValue"],
        ["sqrt","sqrtValue"],["log","logValue"],["sin","sinValue"],["cos","cosValue"],
        ["tan","tanValue"],["clamp","clampValue"]])
        handle.bindFunc!(mixin(pair[1]))(pair[0]);
}
