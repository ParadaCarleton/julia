# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test
using Base: StrictModeError

"Owns a function and a type, so it can legally extend either."
module Vendor
Base.Experimental.@compiler_options strict=true

struct Widget end
struct Gadget{T} end

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
    Core.eval(Vendor, :(Base.show(io::IO, ::Union{Int,Widget}, ::Bool) = nothing))
    @test which(push!, Tuple{Vector{Vendor.Widget}, Vendor.Widget}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Gadget{Int}}).module === Vendor
    @test which(show, Tuple{IO, Vendor.Widget, Bool}).module === Vendor
end

@testset "strict is opt-in and can be switched off" begin
    Core.eval(Lenient, :(Base.show(::IO, ::Int, ::Bool, ::Bool) = nothing))
    @test which(show, Tuple{IO, Int, Bool, Bool}).module === Lenient
    Core.eval(Vendor.Lax, :(Base.show(::IO, ::Int, ::Bool, ::Char) = nothing))
    @test which(show, Tuple{IO, Int, Bool, Char}).module === Vendor.Lax
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
end
