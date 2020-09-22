@testset "report no method matching" begin
    # if there is no method matching case, it should be reported
    let
        # NOTE: we can't just wrap them into `let`, closures can't be inferred correctly
        m = gen_virtualmod()
        interp, frame = Core.eval(m, quote
            foo(a::Integer) = :Integer
            $(profile_call)(AbstractString) do a
                foo(a)
            end
        end)
        @test length(interp.reports) === 1
        report = first(interp.reports)
        @test report isa NoMethodErrorReport &&
            report.atype === Tuple{typeof(m.foo), AbstractString}
    end

    # we want to get report on `zero(Any)` for this case, but `Any`-typed statement can't
    # propagate to the error points ...
    let
        interp, report = profile_call(()->sum([]))
        @test_broken !isempty(interp.reports)
    end

    # if there is no method matching case in union-split, it should be reported
    let
        m = gen_virtualmod()
        interp, frame = Core.eval(m, quote
            foo(a::Integer) = :Integer
            foo(a::AbstractString) = "AbstractString"

            $(profile_call)(a->foo(a), Union{Nothing,Int})
        end)

        @test length(interp.reports) === 1
        report = first(interp.reports)
        @test report isa NoMethodErrorReport && report.atype === Tuple{typeof(m.foo), Union{Nothing,Int}}
    end
end

@testset "report undefined slots" begin
    let
        interp, frame = profile_call(Bool) do b
            if b
                bar = rand(Int)
                return bar
            end
            return bar # undefined in this pass
        end
        @test length(interp.reports) === 1
        @test first(interp.reports) isa LocalUndefVarErrorReport
        @test first(interp.reports).name === :bar
    end

    # deeper level
    let
        m = @def begin
            function foo(b)
                if b
                    bar = rand(Int)
                    return bar
                end
                return bar # undefined in this pass
            end
            baz(a) = foo(a)
        end

        interp, frame = Core.eval(m, :($(profile_call)(baz, Bool)))
        @test length(interp.reports) === 1
        @test first(interp.reports) isa LocalUndefVarErrorReport
        @test first(interp.reports).name === :bar

        # works when cached
        interp, frame = Core.eval(m, :($(profile_call)(baz, Bool)))
        @test length(interp.reports) === 1
        @test first(interp.reports) isa LocalUndefVarErrorReport
        @test first(interp.reports).name === :bar
    end

    # try to exclude false negatives as possible (by collecting reports in after-optimization pass)
    let
        interp, frame = profile_call(Bool) do b
            if b
                bar = rand()
            end

            return if b
                return bar # this shouldn't be reported
            else
                return nothing
            end
        end
        @test isempty(interp.reports)
    end

    let
        interp, frame = profile_call(Bool) do b
            if b
                bar = rand()
            end

            return if b
                return nothing
            else
                # ideally we want to have report for this pass, but tons of work will be
                # needed to report this pass
                return bar
            end
        end
        @test_broken length(interp.reports) === 1 &&
            first(interp.reports) isa LocalUndefVarErrorReport &&
            first(interp.reports).name === :bar
    end
end

@testset "report undefined (global) variables" begin
    let
        interp, frame = profile_call(()->foo)
        @test length(interp.reports) === 1
        @test first(interp.reports) isa GlobalUndefVarErrorReport
        @test first(interp.reports).name === :foo
    end

    # deeper level
    let
        m = @def begin
            foo(bar) = bar + baz
            qux(a) = foo(a)
        end

        interp, frame = Core.eval(m, :($(profile_call)(qux, Int)))
        @test length(interp.reports) === 1
        @test first(interp.reports) isa GlobalUndefVarErrorReport
        @test first(interp.reports).name === :baz

        # works when cached
        interp, frame = Core.eval(m, :($(profile_call)(qux, Int)))
        @test length(interp.reports) === 1
        @test first(interp.reports) isa GlobalUndefVarErrorReport
        @test first(interp.reports).name === :baz
    end
end

@testset "report non-boolean condition error" begin
    let
        interp, frame = profile_call(Int) do a
            a ? a : nothing
        end
        @test length(interp.reports) === 1
        er = first(interp.reports)
        @test er isa NonBooleanCondErrorReport
        @test er.t === Int
    end

    let
        interp, frame = profile_call(Any) do a
            a ? a : nothing
        end
        @test isempty(interp.reports)
    end

    let
        interp, frame = profile_call() do
            anyary = Any[1,2,3]
            first(anyary) ? first(anyary) : nothing
        end
        @test isempty(interp.reports) # very untyped, we can't report on this ...
    end
end

@testset "inference with virtual global variable" begin
    let
        vmod = gen_virtualmod()
        res, interp = @profile_toplevel vmod begin
            s = "julia"
            sum(s)
        end

        @test widenconst(get_virtual_globalvar(interp, vmod, :s)) == String
        test_sum_over_string(res)
    end

    @testset "union assignment" begin
        let
            vmod = gen_virtualmod()
            interp, frame = Core.eval(vmod, :($(profile_call)() do
                global globalvar
                if rand(Bool)
                    globalvar = "String"
                else
                    globalvar = :Symbol
                end
            end))

            @test get_virtual_globalvar(interp, vmod, :globalvar) === Union{String,Symbol}
        end

        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                if rand(Bool)
                    globalvar = "String"
                else
                    globalvar = :Symbol
                end

                foo(s::AbstractString) = length(s)
                foo(globalvar) # union-split no method matching error should be reported
            end

            @test get_virtual_globalvar(interp, vmod, :globalvar) === Union{String,Symbol}
            @test length(res.inference_error_reports) === 1
            er = first(res.inference_error_reports)
            @test er isa NoMethodErrorReport &&
                er.unionsplit # should be true
        end

        # sequential
        let
            vmod = gen_virtualmod()
            res, interp = @profile_toplevel vmod begin
                if rand(Bool)
                    globalvar = "String"
                else
                    globalvar = :Symbol
                end

                foo(s::AbstractString) = length(s)
                foo(globalvar) # union-split no method matching error should be reported

                globalvar = 10
                foo(globalvar) # no method matching error should be reported
            end

            @test get_virtual_globalvar(interp, vmod, :globalvar) ⊑ Int
            @test length(res.inference_error_reports) === 2
            let er = first(res.inference_error_reports)
                @test er isa NoMethodErrorReport &&
                er.unionsplit
            end
            let er = last(res.inference_error_reports)
                @test er isa NoMethodErrorReport &&
                !er.unionsplit
            end
        end
    end

    @testset "invalidate code cache" begin
        let
            res, interp = @profile_toplevel begin
                foo(::Integer) = "good call, pal"
                bar() = a

                a = 1
                foo(bar()) # no method error should NOT be reported

                a = '1'
                foo(bar()) # no method error should be reported

                a = 1
                foo(bar()) # no method error should NOT be reported
            end
            @test length(res.inference_error_reports) === 1
            er = first(res.inference_error_reports)
            @test er isa NoMethodErrorReport &&
                first(er.st).file === Symbol(@__FILE__) &&
                first(er.st).line === (@__LINE__) - 9 &&
                er.atype <: Tuple{Any,Char}
        end
    end
end

@testset "report `throw` calls" begin
    # simplest case
    let
        interp, frame = profile_call(()->throw("foo"))
        @test !isempty(interp.reports)
        @test first(interp.reports) isa ExceptionReport
    end

    # throws in deep level
    let
        foo(a) = throw(a)
        interp, frame = profile_call(()->foo("foo"))
        @test !isempty(interp.reports)
        @test first(interp.reports) isa ExceptionReport
    end

    # don't report possibly false negative `throw`s
    let
        foo(a) = a ≤ 0 ? throw("a is $(a)") : a
        interp, frame = profile_call(foo, Int)
        @test isempty(interp.reports)
    end

    # constant prop sometimes helps exclude false negatives
    let
        foo(a) = a ≤ 0 ? throw("a is $(a)") : a
        interp, frame = profile_call(()->foo(0))
        @test !isempty(interp.reports)
        @test first(interp.reports) isa ExceptionReport
    end

    # don't report if there the other crical error exist
    let
        m = gen_virtualmod()
        interp, frame = Core.eval(m, quote
            foo(a) = sum(a) # should be reported
            bar(a) = throw(a) # shouldn't be reported first
            $(profile_call)(Bool, String) do b, s
                b && foo(s)
                bar(s)
            end
        end)
        @test length(interp.reports) === 2
        test_sum_over_string(interp.reports)
    end

    # end to end
    let
        # this should report `throw(ArgumentError("Sampler for this object is not defined")`
        interp, frame = profile_call(rand, Char)
        @test !isempty(interp.reports)
        @test first(interp.reports) isa ExceptionReport

        # this should not report `throw(DomainError(x, "sin(x) is only defined for finite x."))`
        interp, frame = profile_call(sin, Int)
        @test isempty(interp.reports)

        # again, constant prop sometimes can exclude false negatives
        interp, frame = profile_call(()->sin(Inf))
        @test !isempty(interp.reports)
        @test first(interp.reports) isa ExceptionReport
    end
end

@testset "constant propagation" begin
    # constant prop should limit false positive union-split no method reports
    let
        m = @def begin
            mutable struct P
                i::Int
                s::String
            end
            foo(p, i) = p.i = i
        end

        # "for one of the union split cases, no matching method found for signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Union{Type{Int64}, Type{String}}, v::Int64)" should be threw away
        interp, frame = Core.eval(m, :($(profile_call)(foo, P, Int)))
        @test isempty(interp.reports)

        # works for cache
        interp, frame = Core.eval(m, :($(profile_call)(foo, P, Int)))
        @test isempty(interp.reports)
    end

    # more cache test, constant prop should re-run in deeper level
    let
        m = @def begin
            mutable struct P
                i::Int
                s::String
            end
            foo(p, i) = p.i = i
            bar(args...) = foo(args...)
        end

        # "for one of the union split cases, no matching method found for signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Union{Type{Int64}, Type{String}}, v::Int64)" should be threw away
        interp, frame = Core.eval(m, :($(profile_call)(bar, P, Int)))
        @test isempty(interp.reports)

        # works for cache
        interp, frame = Core.eval(m, :($(profile_call)(bar, P, Int)))
        @test isempty(interp.reports)
    end

    # constant prop should not exclude those are not related
    let
        m = gen_virtualmod()
        interp, frame = Core.eval(m, quote
            mutable struct P
                i::Int
                s::String
            end
            function foo(p, i, s)
                p.i = i
                p.s = s
            end

            $(profile_call)(foo, P, Int, #= invalid =# Int)
        end)

        # "for one of the union split cases, no matching method found for signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Union{Type{Int64}, Type{String}}, v::Int64)" should be threw away, while
        # "no matching method found for call signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Type{String}, v::Int64)" should be kept
        @test length(interp.reports) === 1
        er = first(interp.reports)
        @test er isa NoMethodErrorReport &&
            er.atype === Tuple{typeof(convert), Type{String}, Int}
    end

    # constant prop should narrow down union-split no method error to single no method matching error
    let
        m = gen_virtualmod()
        interp, frame = Core.eval(m, quote
            mutable struct P
                i::Int
                s::String
            end
            function foo(p, i, s)
                p.i = i
                p.s = s
            end

            $(profile_call)(foo, P, String, Int)
        end)

        # "for one of the union split cases, no matching method found for signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Union{Type{Int64}, Type{String}}, v::String)" should be narrowed down to "no matching method found for call signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Type{Int}, v::String)"
        @test !isempty(interp.reports)
        @test any(interp.reports) do report
            return report isa NoMethodErrorReport &&
                report.atype === Tuple{typeof(convert), Type{Int}, String}
        end
        # "no matching method found for call signature: Base.convert(Base.fieldtype(Base.typeof(x::P)::Type{P}, f::Symbol)::Type{String}, v::Int)"
        # won't be reported since `typeinf` early escapes on `Bottom`-annotated statement
    end

    # constant prop and cache
    let
        m = @def begin
            foo(a) = a > 0 ? a : "minus"
            bar(a) = foo(a) + 1
        end

        # yes, we don't want report for this case
        interp, frame = Core.eval(m, :($(profile_call)(()->bar(10))))
        @test isempty(interp.reports)

        # for this case, we want to have union-split error
        interp, frame = Core.eval(m, :($(profile_call)(bar, Int)))
        @test length(interp.reports) === 1
        er = first(interp.reports)
        @test er isa NoMethodErrorReport &&
            er.unionsplit &&
            er.atype ⊑ Tuple{Any,Union{Int,String},Int}

        # if we run constant prop again, we can get reports as expected
        interp, frame = Core.eval(m, :($(profile_call)(()->bar(0))))
        @test length(interp.reports) === 1
        er = first(interp.reports)
        @test er isa NoMethodErrorReport &&
            !er.unionsplit &&
            er.atype ⊑ Tuple{Any,String,Int}
    end

    # should threw away previously-collected reports from frame that is lineage of
    # current constant prop'ed frame
    let
        m = @def begin
            foo(a) = bar(a)
            function bar(a)
                return if a < 1
                    baz1(a, "0")
                else
                    baz2(a, a)
                end
            end
            baz1(a, b) = a ? b : b
            baz2(a, b) = a + b
        end

        # no constant prop, just report everything
        interp, frame = Core.eval(m, :($(profile_call)(foo, Int)))
        @test length(interp.reports) === 1
        er = first(interp.reports)
        @test er isa NonBooleanCondErrorReport &&
            er.t === Int

        # constant prop should throw away non-boolean condition reports within `baz1`
        interp, frame = Core.eval(m, quote
            $(profile_call)() do
                foo(10)
            end
        end)
        @test isempty(interp.reports)

        # constant prop'ed, still we want to have reports for this
        interp, frame = Core.eval(m, quote
            $(profile_call)() do
                foo(0)
            end
        end)
        @test er isa NonBooleanCondErrorReport &&
            er.t === Int

        interp, frame = Core.eval(m, quote
            $(profile_call)() do
                foo(false)
            end
        end)
        @test isempty(interp.reports)
    end
end
