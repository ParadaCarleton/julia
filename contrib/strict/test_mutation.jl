using Test
include(joinpath(@__DIR__, "mutation.jl"))

mutable struct Box; a::Int; inner::Vector{Int}; end
const GLOB = Int[1]

direct(v)    = (v[1] = 3; v)                        # writes an argument
aliased(v)   = (w = v; push!(w, 1); w)              # writes it through a copy
setprop(x)   = (x.a = 1; x)                         # setproperty! on an argument
viafield(x)  = (y = x.inner; push!(y, 1); x)        # reaches in via getfield
readonly(b)  = (t = similar(b); copyto!(t, b); t)   # argument only in a read slot
fresh()      = (v = Int[]; push!(v, 1); v)          # writes memory it made
addup(a, b)  = a + b
reads(v)     = length(v)
globwrite()  = (GLOB[1] = 1; nothing)
bangclean!(x) = x === nothing                       # named ! but writes nothing
helper(x)    = (x[1] = 1; nothing)
outer(x)     = helper(x)                            # writes through a non-! helper
viaindex(x)  = (x[1][1] = 1; nothing)               # reaches in via getindex
fresh_memory() = Core.memorynew(Memory{Int}, 1)     # builtins only, so fully followed
memwrite(m)  = Core.memoryrefset!(Core.memoryrefnew(m), 1, :not_atomic, true)
rebound(x)   = (y = x; y = fresh_memory(); memwrite(y); y)  # slot reassigned to fresh memory
stashed(x)   = (c = Box(0, x); setfield!(c, :inner, x); getfield(c, :inner)[1] = 1; c)  # stored, read back
fieldread(b::Box) = getfield(b, :a)
viahelper(b::Box) = fieldread(b)
opaquecall(f, x) = f(x)
viaccall(x)  = ccall(:jl_typeof_str, Cstring, (Any,), x)

kind(f) = mutation_kind(first(code_lowered(f)), first(methods(f)).nargs)

@testset "writes through an argument" begin
    @test kind(direct)   === :writes_arg
    @test kind(aliased)  === :writes_arg
    @test kind(setprop)  === :writes_arg
    @test kind(viafield) === :writes_arg
    @test kind(outer)    === :writes_arg
    @test kind(viaindex) === :writes_arg
    @test kind(stashed)  === :writes_arg
end

@testset "never claims clean for what it cannot follow" begin
    @test kind(opaquecall) === :unknown
    @test kind(viaccall)   === :unknown
end

@testset "does not write through an argument" begin
    @test kind(rebound)   === :clean
    @test kind(viahelper) === :clean
    # Untyped calls with many dispatch candidates stay unknown, never a write.
    for f in (readonly, fresh, addup, reads)
        @test kind(f) in (:clean, :unknown)
    end
end

@testset "globals" begin
    globalias()  = (g = GLOB; push!(g, 1); nothing)
    @test kind(globwrite) === :writes_global
    @test kind(globalias) === :writes_global
end

@testset "verdict pairs name with body" begin
    @test verdict(first(methods(direct)))     === :writes_arg
    @test verdict(first(methods(viahelper)))  === :ok
    @test verdict(first(methods(opaquecall))) === :unknown
    @test verdict(first(methods(bangclean!))) === :bang_but_clean
    @test verdict(first(methods(push!, Tuple{Vector{Int},Int}))) === :ok
end
