# How much of Base a "side effects require !" rule would flag, and how much of
# that is only ccall opacity. Infers twice over the same methods, once trusting
# ccall and once not. The custom interpreter's cache never reaches codegen.

const CC = isdefined(Base, :Compiler) ? Base.Compiler : Core.Compiler

const SPECS_PER_METHOD = 5  # bound the work; methods vary little across specializations

struct PurityInterp <: CC.AbstractInterpreter
    trust_ccall::Bool
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}
end

function PurityInterp(trust_ccall::Bool)
    return PurityInterp(trust_ccall, Base.get_world_counter(), CC.InferenceParams(),
                        CC.OptimizationParams(), CC.InferenceResult[])
end

CC.InferenceParams(i::PurityInterp) = i.inf_params
CC.OptimizationParams(i::PurityInterp) = i.opt_params
CC.get_inference_world(i::PurityInterp) = i.world
CC.get_inference_cache(i::PurityInterp) = i.inf_cache

function CC.cache_owner(i::PurityInterp)
    if i.trust_ccall
        return :purity_trusting_ccall
    end
    return :purity_plain
end

"""
Treat every `ccall` as total, leaving only the effects Julia performs itself.
The difference against the stock verdict is exactly what ccall opacity costs.
"""
function CC.abstract_eval_foreigncall(i::PurityInterp, e::Expr,
                                      sstate::CC.StatementState, sv::CC.AbsIntState)
    r = @invoke CC.abstract_eval_foreigncall(i::CC.AbstractInterpreter, e::Expr,
                                             sstate::CC.StatementState, sv::CC.AbsIntState)
    if i.trust_ccall
        return CC.RTEffects(r.rt, r.exct, CC.EFFECTS_TOTAL, r.refinements)
    end
    return r
end

"""Concrete argument tuples this method has actually been called with."""
function specializations(m::Method)
    s = m.specializations
    mis = s isa Core.MethodInstance ? Core.MethodInstance[s] :
          Core.MethodInstance[x for x in s if x isa Core.MethodInstance]
    out = Any[]
    for mi in mis
        st = mi.specTypes
        if !(st isa DataType)
            continue
        end
        args = st.parameters[2:end]
        if any(p -> p isa TypeVar || p isa Core.TypeofVararg || !Base.isconcretetype(p), args)
            continue
        end
        push!(out, Tuple{args...})
        if length(out) == SPECS_PER_METHOD
            break
        end
    end
    return out
end

"""
Coarsest caller-visible effect over `m`'s specializations: `:pure`, `:writes_args`
when it writes memory reachable from an argument, `:unknown` otherwise.
"""
function verdict(f, m::Method, tts, interp::PurityInterp)
    worst = 0
    for tt in tts
        e = try
            Base.infer_effects(f, tt; interp)
        catch
            continue
        end
        ef = e.effect_free
        rank = if ef === CC.ALWAYS_TRUE || ef === CC.EFFECT_FREE_GLOBALLY
            0
        elseif ef === CC.EFFECT_FREE_IF_INACCESSIBLEMEMONLY
            1
        else
            2
        end
        worst = max(worst, rank)
    end
    return (:pure, :writes_args, :unknown)[worst + 1]
end

# Base.:! is negation, not the mutation suffix.
bang(m::Method) = endswith(String(m.name), "!") && m.name !== :!

function scan()
    plain, trusting = PurityInterp(false), PurityInterp(true)
    rows = NamedTuple{(:m, :plain, :trusting),Tuple{Method,Symbol,Symbol}}[]
    for nm in names(Base)
        if startswith(String(nm), "@") || !isdefined(Base, nm)
            continue
        end
        f = getglobal(Base, nm)
        if !(f isa Function)
            continue
        end
        for m in methods(f).ms
            tts = specializations(m)
            if isempty(tts)
                continue
            end
            push!(rows, (; m, plain = verdict(f, m, tts, plain),
                           trusting = verdict(f, m, tts, trusting)))
        end
    end
    return rows
end

rows = scan()
unbanged = filter(r -> !bang(r.m), rows)
banged = filter(r -> bang(r.m), rows)

function table(title, rs)
    println(title, "  (n=", length(rs), ")")
    println("                       ccall opaque   ccall trusted")
    for v in (:pure, :writes_args, :unknown)
        println("  ", rpad(v, 20), lpad(count(r -> r.plain === v, rs), 8),
                lpad(count(r -> r.trusting === v, rs), 15))
    end
    println()
end

println("methods analyzed (>=1 concrete specialization): ", length(rows), "\n")
table("named WITHOUT !", unbanged)
table("named WITH !", banged)

println("named without ! but writes argument memory — what the rule catches:")
for m in first([r.m for r in unbanged if r.trusting === :writes_args], 18)
    println("  ", m.name, "  ", m.sig)
end
println()
println("named with ! but provably pure — decoration:")
for m in first([r.m for r in banged if r.trusting === :pure], 12)
    println("  ", m.name, "  ", m.sig)
end
