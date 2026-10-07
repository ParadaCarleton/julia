# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Signature of the `Core.kwcall` method that resolves positional arguments passed
by name. It matches every keyword call, so reflection that asks whether a keyword
sorter exists compares against it.
"""
const KWCALL_BY_NAME_SIG = Tuple{typeof(Core.kwcall), NamedTuple, Any, Vararg{Any}}

"""
    nameable_parameters(m::Method) -> Vector{Symbol}

Declared names of `m`'s fixed positional parameters, excluding the function slot
and any trailing vararg slot. A vararg tail takes whatever positional arguments
are left over, so no name selects a place within it.
"""
function nameable_parameters(m::Method)::Vector{Symbol}
    fixed = m.nargs - 1
    if m.isva
        fixed = m.nargs - 2
    end
    return collect(Iterators.take(Iterators.drop(method_argnames(m), 1), max(fixed, 0)))
end

"""
    name_order(m::Method, npositional::Integer, given::Tuple{Vararg{Symbol}}) -> Union{Vector{Symbol},Nothing}

Names that must be read from keyword arguments, in declaration order, to complete
a call to `m` that already supplies `npositional` leading positional arguments.
`nothing` when `given` cannot complete `m`.
"""
function name_order(m::Method, npositional::Integer, given::Tuple{Vararg{Symbol}})::Union{Vector{Symbol},Nothing}
    slots = nameable_parameters(m)
    if npositional > length(slots)
        return nothing
    end
    order = collect(Iterators.drop(slots, npositional))
    # An empty order retries the identical call, so it must be rejected here.
    if isempty(order)
        return nothing
    end
    if !issubset(order, given)
        return nothing
    end
    keywords = kwarg_decl(m)
    if any(name -> endswith(String(name), "..."), keywords)
        return order
    end
    for name in given
        if !(name in order) && !(name in keywords)
            return nothing
        end
    end
    return order
end

"""
    reorder(args::Tuple, kwargs::NamedTuple, order::AbstractVector{Symbol}) -> Tuple

The positional arguments of the completed call: `args` followed by the values of
`kwargs` named by `order`.
"""
function reorder(args::Tuple, kwargs::NamedTuple, order::AbstractVector{Symbol})::Tuple
    return (args..., (getfield(kwargs, name) for name in order)...)
end

"""
    fitted_order(m::Method, f, args::Tuple, kwargs::NamedTuple) -> Union{Vector{Symbol},Nothing}

[`name_order`](@ref) for `m`, kept only when the reordered arguments also match
`m`'s signature.
"""
function fitted_order(m::Method, @nospecialize(f), args::Tuple, kwargs::NamedTuple)::Union{Vector{Symbol},Nothing}
    order = name_order(m, length(args), keys(kwargs))
    if order === nothing
        return nothing
    end
    reordered = reorder(args, kwargs, order)
    if !(Tuple{Core.Typeof(f), map(Core.Typeof, reordered)...} <: m.sig)
        return nothing
    end
    return order
end

"""
    by_name_orders(kwargs::NamedTuple, f, args::Tuple)

The distinct [`fitted_order`](@ref)s over all methods of `f`, one ragged entry per
candidate. One entry means the call resolves; more than one means the names are
ambiguous.
"""
function by_name_orders(kwargs::NamedTuple, @nospecialize(f), args::Tuple)::AbstractVector
    return unique([order for order in (fitted_order(m, f, args, kwargs) for m in methods(f))
                   if order !== nothing])
end

"""
    by_name_applicable(kwargs::NamedTuple, f, args::Tuple) -> Bool

Whether [`kwcall_by_name`](@ref) completes `f(args...; kwargs...)`.
"""
function by_name_applicable(kwargs::NamedTuple, @nospecialize(f), args::Tuple)::Bool
    return length(by_name_orders(kwargs, f, args)) == 1
end

"""
    resolves_without_fallback(kwargs::NamedTuple, args::Tuple) -> Bool

Whether a keyword sorter, rather than the by-name fallback, handles
`Core.kwcall(kwargs, args...)`.
"""
function resolves_without_fallback(kwargs::NamedTuple, args::Tuple)::Bool
    sig = Tuple{typeof(Core.kwcall), typeof(kwargs), map(Core.Typeof, args)...}
    match = ccall(:jl_gf_invoke_lookup, Any, (Any, Any, UInt), sig, nothing, get_world_counter())
    if match === nothing
        return false
    end
    return (match::Method).sig !== KWCALL_BY_NAME_SIG
end

"""
    kwcall_by_name(kwargs::NamedTuple, f, args::Tuple)

Complete `f(args...; kwargs...)` by treating keyword arguments that name
positional parameters of `f` as those arguments, then dispatching normally.
Throws the `MethodError` the call would otherwise have raised when no method of
`f` can be completed this way.
"""
function kwcall_by_name(kwargs::NamedTuple, @nospecialize(f), args::Tuple)
    @noinline
    orders = by_name_orders(kwargs, f, args)
    if isempty(orders)
        throw(MethodError(Core.kwcall, (kwargs, f, args...), tls_world_age()))
    end
    if length(orders) > 1
        throw(ArgumentError(LazyString("calling ", f, " by argument name is ambiguous: ",
                                       "candidate parameter orders ", orders)))
    end
    order = only(orders)
    reordered = reorder(args, kwargs, order)
    # Each retry carries strictly fewer keywords, so the recursion terminates.
    rest = structdiff(kwargs, NamedTuple{(order...,)})
    if isempty(rest)
        return f(reordered...)
    end
    return Core.kwcall(rest, f, reordered...)
end

"""
    Core.kwcall(kwargs::NamedTuple, f, args...)

Fallback for a keyword call no keyword sorter accepts: resolve the keywords
against the positional parameter names of `f`'s methods.
"""
function Core.kwcall(kwargs::NamedTuple, @nospecialize(f), @nospecialize(args...))::Any
    @noinline
    return kwcall_by_name(kwargs, f, args)
end
