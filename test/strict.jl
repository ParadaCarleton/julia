# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test, Random
using Base: StrictModeError

include("strict_oracle.jl")

"Owns a function and a type, so it can legally extend either."
module Vendor
Base.Experimental.@compiler_options strict=true

struct Widget end
struct Gadget{T} end
abstract type Shape end

frob(x) = x
Base.show(io::IO, ::Widget) = print(io, "widget")
Base.convert(::Type{Widget}, ::Int) = Widget()
Widget(::Float64) = Widget()
Base.sort(::Widget; rev::Bool=false) = rev

module Sub
using ..Vendor: Widget
twiddle(::Widget) = 1
end

module Lax
Base.Experimental.@compiler_options strict=false
end
end

module Lenient end

@testset "strict modules define what they own" begin
    @test Vendor.frob(1) == 1                       # own function, foreign types
    @test sprint(show, Vendor.Widget()) == "widget" # foreign function, own type
    @test convert(Vendor.Widget, 1) isa Vendor.Widget
    @test Vendor.Widget(1.0) isa Vendor.Widget      # own constructor
    @test sort(Vendor.Widget(); rev=true)           # keyword method, own type
    @test Vendor.Sub.twiddle(Vendor.Widget()) == 1  # submodule inherits strict
end

@testset "strict modules reject piracy" begin
    @test_throws StrictModeError Core.eval(Vendor, :(Base.:+(a::Int, b::Int) = 0))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Float64) = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.push!(v::Vector{Int}, x::Int) = v))
    # An owned type under Type{} rescues a definition; a foreign one does not.
    @test_throws StrictModeError Core.eval(Vendor, :(Base.convert(::Type{Int}, ::String) = 0))
    # Rejecting means the method table is untouched.
    @test !any(m -> m.module === Vendor, methods(+).ms)
end

@testset "types reached through parameters are owned" begin
    # A qualified definition evaluates to nothing, so assert against the method table.
    Core.eval(Vendor, :(Base.push!(v::Vector{Widget}, x::Widget) = v))
    Core.eval(Vendor, :(Base.show(io::IO, ::Gadget{T}) where {T} = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Union{Widget,Gadget}, ::Bool) = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Shape, ::Bool) = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::T, ::Char) where {T<:Widget} = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Vector{<:Widget}, ::Char) = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Val{Widget()}) = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Bool, xs::Vararg{Widget,2}) = nothing))
    Core.eval(Vendor, :(Base.show(io::IO, ::Widget, xs::Int...) = nothing))
    @test which(push!, Tuple{Vector{Vendor.Widget}, Vendor.Widget}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Gadget{Int}}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Widget, Bool}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Shape, Bool}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Widget, Char}).module === Vendor
    @test which(show, Tuple{IO, Vector{Vendor.Widget}, Char}).module === Vendor
    @test which(show, Tuple{IO, Val{Vendor.Widget()}}).module === Vendor
    @test which(show, Tuple{IO, Bool, Vendor.Widget, Vendor.Widget}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Widget, Int, Int}).module === Vendor
end

@testset "signatures that also match foreign arguments are piracy" begin
    owned_shows() = count(m -> m.module === Vendor, methods(show).ms)
    before = owned_shows()
    # Each signature matches a call made only of foreign types, noted alongside.
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Union{Int,Widget}, ::Bool) = nothing))  # (IO, Int, Bool)
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Real, ::Bool) = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::T, ::Bool) where {T<:Union{Int,Widget}} = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Vector{T}) where {T} = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Vector{<:Union{Int,Widget}}) = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Bool, xs::Widget...) = nothing))  # (IO, Bool)
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Bool, xs::Vararg{Widget,N}) where {N} = nothing))
    @test_throws StrictModeError Core.eval(Vendor, :(Base.show(io::IO, ::Tuple{Vararg{Widget}}) = nothing))  # (IO, Tuple{})
    @test owned_shows() == before
    @test_throws StrictModeError Core.eval(Vendor, :((::Union{typeof(+),typeof(frob)})(a::Int, b::Int) = 0))
    @test !any(m -> m.module === Vendor, methods(+).ms)
end

@testset "strict is opt-in and can be switched off" begin
    Core.eval(Lenient, :(Base.show(::IO, ::Int, ::Bool, ::Bool) = nothing))
    @test which(show, Tuple{IO, Int, Bool, Bool}).module === Lenient
    Core.eval(Vendor.Lax, :(Base.show(::IO, ::Int, ::Bool, ::Char) = nothing))
    @test which(show, Tuple{IO, Int, Bool, Char}).module === Vendor.Lax
end

@testset "JULIA_STRICT defaults user modules to strict and leaves Base alone" begin
    script = """
        # Base defining a method of a Core type on Core arguments would be piracy if Base were strict.
        Core.eval(Base, :((::Type{Core.TypeError})(::Signed, ::Signed, ::Signed, ::Signed, ::Signed) = nothing))
        module Pirate end
        try
            Core.eval(Pirate, :(Base.show(::IO, ::Signed, ::AbstractChar, ::AbstractChar) = nothing))
            print("accepted")
        catch err
            print(nameof(typeof(err)))
        end
        """
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no -e $script`, "JULIA_STRICT" => "1")
    @test read(cmd, String) == "StrictModeError"
end

@testset "error names the module and the owners" begin
    err = try
        Core.eval(Vendor, :(Base.show(io::IO, ::Float32) = nothing))
    catch e
        e
    end
    @test err isa StrictModeError
    msg = sprint(showerror, err)
    @test occursin("type piracy", msg)
    @test occursin("Vendor", msg)
    @test occursin("Base", msg)
    # A signature that names an owned type still lists only the foreign owners.
    err = try
        Core.eval(Vendor, :(Base.show(io::IO, ::Union{Int,Widget}, ::Char) = nothing))
    catch e
        e
    end
    owners = last(split(sprint(showerror, err), "owns none of: "))
    @test occursin("Core", owners)
    @test !occursin("Vendor", owners)
end

@testset "the rule rejects every signature that matches foreign-only arguments" begin
    pick = StrictOracle.RandomPick(Random.Xoshiro(0x5715))
    sigs = [StrictOracle.random_signature(pick, 2) for _ in 1:500]
    piratical = filter(sig -> StrictOracle.foreign_witness(sig) !== nothing, sigs)
    @test length(piratical) > 100
    @test isempty(filter(sig -> !Base._is_piracy(StrictOracle, sig), piratical))
    # measured: the rule also rejects ~25% of signatures with no witness, mostly because UNIVERSE is finite.
end
