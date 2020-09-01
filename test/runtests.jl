using Test, TypeProfiler, InteractiveUtils
import TypeProfiler:
    TPInterpreter, virtual_process!, report_errors,
    ToplevelErrorReport, SyntaxErrorReport, ActualErrorWrapped,
    InferenceErrorReport, NoMethodErrorReport, InvalidBuiltinCallErrorReport,
    UndefVarErrorReport, NonBooleanCondErrorReport, NativeRemark


const FIXTURE_DIR = normpath(@__DIR__, "fixtures")
gen_mod() = Core.eval(@__MODULE__, :(module $(gensym(:TypeProfilerTest)) end))

@testset "virtualprocess" begin
    include("test_virtualprocess.jl")
end

# # favorite
# # --------
#
# # never ends otherwise
# fib(n) = n ≤ 2 ? n : fib(n-1) + fib(n-2)
# @profile_call fib(100000) # ::Int
# @profile_call fib(100000.) # ::Float64
# @profile_call fib(100000 + 100000im) # report !
#
#
# # undef var
# # ---------
#
# undef(a) = return foo(a)
# @profile_call undef(0)
#
#
# # non-boolean condition
# # ---------------------
#
# nonbool(a) = a ? a : nothing
# nonbool() = (c = rand(Any[1,2,3])) #=c is Any typed=# ? c : nothing
#
# @profile_call nonbool(1) # report
# @profile_call nonbool(true) # not report
# @profile_call nonbool() # can't report because it's untyped
#
#
# # no matching method
# # ------------------
#
# # single match
# @profile_call sum("julia")
# @profile_call sum(Char[])
# @profile_call sum([]) # the actual error (i.e. no method for `zero(Any)`) gets buriled in the "Too many methods matched" heuristic
#
# # union splitting
# nomethod_partial(a) = sin(a)
# let
#     interp, frame = profile_call_gf(Tuple{typeof(nomethod_partial), Union{Int,Char}})
#     print_reports(stdout, interp.reports)
# end
