# Internals of JET.jl

## Abstract Interpretation Based Analysis

JET.jl overloads functions with the [`Core.Compiler.AbstractInterpreter` interface](https://github.com/JuliaLang/julia/blob/master/base/compiler/types.jl), and customizes its abstract interpretation routine.
The overloads are done on `JETInterpreter <: AbstractInterpreter` so that `typeinf(::JETInterpreter, ::InferenceState)` will do the customized abstract interpretation and collect type errors.

Most overloads use the [`invoke`](https://docs.julialang.org/en/v1/base/base/#Core.invoke) reflection, which allows
`JETInterpreter` to dispatch to the original `AbstractInterpreter`'s abstract interpretation methods and still keep passing
it to the subsequent (maybe overloaded) callees (see [`JET.@invoke`](@ref) macro).

```@docs
JET.bail_out_toplevel_call
JET.bail_out_call
JET.add_call_backedges!
JET.const_prop_entry_heuristic
JET.analyze_task_parallel_code!
JET.is_from_same_frame
JET.AbstractGlobal
```


## Top-level Analysis

```@docs
JET.virtual_process
JET.ConcreteInterpreter
JET.partially_interpret!
```


## Utilities

```@docs
JET.@invoke
JET.@invokelatest
JET.@withmixedhash
JET.@jetconfigurable
```
