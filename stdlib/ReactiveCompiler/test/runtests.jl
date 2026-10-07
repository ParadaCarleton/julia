# This file is a part of Julia. License is MIT: https://julialang.org/license

# The harness is in the system image and exposes the server protocol's entry points.
using Test, ReactiveCompiler

@testset "ReactiveCompiler" begin
    @test isdefined(ReactiveCompiler, :serve)
    @test hasmethod(ReactiveCompiler.serve, Tuple{String})
    @test hasmethod(ReactiveCompiler.trim_entrypoints!, Tuple{})
end
