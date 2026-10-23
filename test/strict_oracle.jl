# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Random signatures and a subtyping oracle for the strict-mode piracy rule.

A signature is piracy when some argument tuple built only from `UNIVERSE` matches it.
`Base._is_piracy(StrictOracle, sig)` must hold for every such signature.
"""
module StrictOracle

abstract type AbstractWidget end
struct Widget end
struct Cog <: AbstractWidget end

# Simpler options come first, so a shrinker that lowers choices simplifies the type.
const FOREIGN_LEAVES = (Int, Integer, Real, Any, String, Symbol, Nothing)
const LEAVES = (FOREIGN_LEAVES..., Widget, AbstractWidget, Cog)
const VALS = (1, :x, Widget(), Cog())

"Concrete types that name only foreign types, so they witness piracy."
const UNIVERSE = DataType[Int, Float64, Bool, String, Symbol, Nothing,
    map(L -> Vector{L}, FOREIGN_LEAVES)..., map(L -> Type{L}, FOREIGN_LEAVES)...,
    Vector{Union{Int,String}}, Vector{Vector{Int}}, Tuple{}, Tuple{Int}, Tuple{Int,String},
    Val{1}, Val{:x}]

"The callee of every generated signature; foreign to `StrictOracle`."
const F = typeof(+)

"Draws choices from `rng`."
struct RandomPick{R}
    rng::R
end
(p::RandomPick)(n::Int) = rand(p.rng, 1:n)

"""
    random_type(pick, depth)

A type from the grammar: leaves, `Union`, `Vector{X}`, `Vector{<:X}`, `Tuple`, `Type{X}`
and `Val{v}`. `pick(n)` returns a choice in `1:n`.
"""
function random_type(pick, depth::Int)
    kind = depth == 0 ? 1 : pick(7)
    if kind == 1
        return LEAVES[pick(length(LEAVES))]
    elseif kind == 2
        return Union{random_type(pick, depth - 1), random_type(pick, depth - 1)}
    elseif kind == 3
        return Vector{random_type(pick, depth - 1)}
    elseif kind == 4
        tv = TypeVar(:T, random_type(pick, depth - 1))
        return UnionAll(tv, Vector{tv})
    elseif kind == 5
        elems = ntuple(_ -> random_type(pick, depth - 1), pick(3) - 1)
        return Tuple{elems..., random_tail(pick, depth - 1)...}
    elseif kind == 6
        return Type{random_type(pick, depth - 1)}
    else
        return Val{VALS[pick(length(VALS))]}
    end
end

"No tail, `Vararg{X}`, or `Vararg{X,N}` with `N` in `0:2`, as a tuple of at most one element."
function random_tail(pick, depth::Int)
    kind = pick(3)
    if kind == 1
        return ()
    end
    T = random_type(pick, depth)
    return kind == 2 ? (Vararg{T},) : (Vararg{T, pick(3) - 1},)
end

"""
    random_signature(pick, depth)

`Tuple{F, args..., tail...}` with up to 3 arguments, each a type or a typevar bounded
by one, wrapped in the `UnionAll`s those typevars need.
"""
function random_signature(pick, depth::Int)
    args = ntuple(_ -> random_argument(pick, depth), pick(4) - 1)
    sig = Tuple{F, args..., random_tail(pick, depth)...}
    for arg in reverse(args)
        if arg isa TypeVar
            sig = UnionAll(arg, sig)
        end
    end
    return sig
end

random_argument(pick, depth::Int) = pick(2) == 1 ? random_type(pick, depth) : TypeVar(:T, random_type(pick, depth))

"Members of `UNIVERSE` that position `i` of an `n`-argument call may hold under `sig`."
function slot_candidates(@nospecialize(sig), n::Int, i::Int)
    # typeintersect may over-approximate, so it only prunes; `<:` in foreign_witness decides.
    fits = falses(length(UNIVERSE))
    for (k, u) in pairs(UNIVERSE)
        fits[k] = typeintersect(Tuple{F, fill(Any, i - 1)..., u, fill(Any, n - i)...}, sig) !== Union{}
    end
    return UNIVERSE[fits]
end

"""
    foreign_witness(sig)

An argument tuple of `UNIVERSE` types, with 0 to 3 elements, that `sig` matches; else `nothing`.
Loops replace closures here: a closure over `sig` would recompile for every signature.
"""
function foreign_witness(@nospecialize(sig))
    for n in 0:3
        slots = Vector{Vector{DataType}}(undef, n)  # ragged: each position keeps its own candidates
        for i in eachindex(slots)
            slots[i] = slot_candidates(sig, n, i)
        end
        for t in Iterators.product(slots...)
            if Tuple{F, t...} <: sig
                return t
            end
        end
    end
    return nothing
end

end
