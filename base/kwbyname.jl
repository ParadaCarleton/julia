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
    keyword_types(kwtype::Type) -> NamedTuple

The declared type of each keyword argument of a `NamedTuple` type, keyed by name.
"""
function keyword_types(@nospecialize(kwtype::Type))::NamedTuple
    names, types = kwtype.parameters
    return NamedTuple{names}(Tuple(types.parameters))
end

"""
    fitted_order(m::Method, ftype::Type, argtypes::Tuple, kwargtypes::NamedTuple) -> Union{Vector{Symbol},Nothing}

[`name_order`](@ref) for `m`, kept only when the reordered argument types also
match `m`'s signature.
"""
function fitted_order(m::Method, @nospecialize(ftype::Type), argtypes::Tuple, kwargtypes::NamedTuple)::Union{Vector{Symbol},Nothing}
    order = name_order(m, length(argtypes), keys(kwargtypes))
    if order === nothing
        return nothing
    end
    reordered = (argtypes..., (getfield(kwargtypes, name) for name in order)...)
    if !(Tuple{ftype, reordered...} <: m.sig)
        return nothing
    end
    return order
end

"""
    by_name_orders(ftype::Type, argtypes::Tuple, kwargtypes::NamedTuple, world::Integer)

The distinct [`fitted_order`](@ref)s over all methods of `ftype` visible in
`world`, one ragged entry per candidate. One entry means the call resolves; more
than one means the names are ambiguous.

Every input is a type, so the answer depends only on the argument types and on
the method table of `ftype` — the inputs ordinary dispatch already consumes.
"""
function by_name_orders(@nospecialize(ftype::Type), argtypes::Tuple, kwargtypes::NamedTuple, world::Integer)::AbstractVector
    matches = _methods_by_ftype(Tuple{ftype, Vararg{Any}}, -1, UInt(world))
    if !isa(matches, Vector)
        return Vector{Symbol}[]
    end
    orders = (fitted_order((match::Core.MethodMatch).method, ftype, argtypes, kwargtypes)
              for match in matches)
    return unique([order for order in orders if order !== nothing])
end

"""
    by_name_applicable(kwargs::NamedTuple, f, args::Tuple) -> Bool

Whether [`kwcall_by_name`](@ref) completes `f(args...; kwargs...)`.
"""
function by_name_applicable(kwargs::NamedTuple, @nospecialize(f), args::Tuple)::Bool
    orders = by_name_orders(Core.Typeof(f), map(Core.Typeof, args),
                            map(Core.Typeof, kwargs), get_world_counter())
    return length(orders) == 1
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
    orders = by_name_orders(Core.Typeof(f), map(Core.Typeof, args),
                            map(Core.Typeof, kwargs), get_world_counter())
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
    kwcall_by_name_body(order::AbstractVector{Symbol}, names::Tuple{Vararg{Symbol}}) -> Expr

The resolved call, reading each named parameter straight out of `kwargs`. Any
keyword left over after `order` is consumed goes back through `Core.kwcall` for a
real keyword sorter to handle.
"""
function kwcall_by_name_body(order::AbstractVector{Symbol}, names::Tuple{Vararg{Symbol}}, argtypes::Tuple)::Expr
    # Splatting `args` would lower to `_apply_iterate` and lose inference; the
    # arity is known here, so read each slot out by position instead.
    positional = ((Expr(:call, GlobalRef(Core, :getfield), :args, slot) for slot in eachindex(argtypes))...,
                  (Expr(:call, GlobalRef(Core, :getfield), :kwargs, QuoteNode(name)) for name in order)...)
    rest = filter(name -> !(name in order), names)
    if isempty(rest)
        return Expr(:return, Expr(:call, :f, positional...))
    end
    leftover = Expr(:call, GlobalRef(Base, :structdiff), :kwargs, NamedTuple{(order...,)})
    return Expr(:return, Expr(:call, GlobalRef(Core, :kwcall), leftover, :f, positional...))
end

"""
    kwcall_by_name_generator(world, source, self, kwtype, ftype, given...) -> CodeInfo

Resolve a by-name keyword call during inference and emit the direct call it
stands for. The generated code carries a method-table edge for `ftype`, so
defining a further method of that function invalidates it.

`given` holds one type per positional argument, the form a generator receives a
vararg tail in — not the tuple type of the tail.

Calls that do not resolve to exactly one parameter order are left to
[`kwcall_by_name`](@ref), which raises the error describing why. So is anything
this generator cannot see through, since a generator that throws degrades to the
run-time body without saying so.
"""
function kwcall_by_name_generator(world::Integer, source::Method, @nospecialize(self), @nospecialize(kwtype),
                                  @nospecialize(ftype), @nospecialize(given))::Any
    argnames = Core.svec(:self, :kwargs, :f, :args)
    stub = Core.GeneratedFunctionStub(identity, argnames, Core.svec())
    deferred = Expr(:return, Expr(:call, GlobalRef(Base, :kwcall_by_name), :kwargs, :f, :args))
    if !isa(kwtype, DataType) || !(kwtype <: NamedTuple) || !isa(ftype, DataType)
        return stub(world, source, deferred)
    end
    argtypes = Tuple(given)
    orders = by_name_orders(ftype, argtypes, keyword_types(kwtype), world)
    if length(orders) != 1
        return stub(world, source, deferred)
    end
    code = stub(world, source, kwcall_by_name_body(only(orders), kwtype.parameters[1], argtypes))
    # Resolution reads the method table of `ftype`; this edge invalidates it on change.
    (code::CodeInfo).edges = Any[Tuple{ftype, Vararg{Any}}, Core.methodtable]
    return code
end

# Fallback for a keyword call no keyword sorter accepts. The generator resolves it
# during inference; the body below serves whenever the generator cannot run.
@eval function Core.kwcall(kwargs::NamedTuple, f, args...)
    $(Expr(:meta, :generated, kwcall_by_name_generator))
    return kwcall_by_name(kwargs, f, args)
end
