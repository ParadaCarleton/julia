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
bangclean!(x) = x + 1                               # named ! but writes nothing

kind(f) = mutation_kind(first(code_lowered(f)), first(methods(f)).nargs)

@testset "writes through an argument" begin
    @test kind(direct)   === :writes_arg
    @test kind(aliased)  === :writes_arg
    @test kind(setprop)  === :writes_arg
    @test kind(viafield) === :writes_arg
end

@testset "does not write through an argument" begin
    @test kind(readonly) === :clean   # argument sits in copyto!'s source position
    @test kind(fresh)    === :clean
    @test kind(addup)    === :clean
    @test kind(reads)    === :clean
end

@testset "globals" begin
    globalias()  = (g = GLOB; push!(g, 1); nothing)
    @test kind(globwrite) === :writes_global
    @test kind(globalias) === :writes_global
end

@testset "verdict pairs name with body" begin
    @test verdict(first(methods(direct)))     === :writes_arg
    @test verdict(first(methods(readonly)))   === :ok
    @test verdict(first(methods(bangclean!))) === :bang_but_clean
    @test verdict(first(methods(push!, Tuple{Vector{Int},Int}))) === :ok
end
