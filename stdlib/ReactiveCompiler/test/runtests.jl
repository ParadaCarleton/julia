# This file is a part of Julia. License is MIT: https://julialang.org/license

# The ledger diff of the rebuild child, and the dispatch of the compiler server's requests.
using Test, ReactiveCompiler
using ReactiveCompiler.ReactiveSourceDiff: changed_expressions, defined_name

const BEFORE = """
module Demo
f(x) = x + 1
g(x) = f(x) * 2
h(x) = x
end
"""

diff(old, new) = changed_expressions(old, new, "demo.jl")

@testset "SourceDiff" begin
    same = diff(BEFORE, BEFORE)
    @test isempty(same.changed) && isempty(same.removed)

    # An edit above every expression moves their lines and changes none of them.
    shifted = diff(BEFORE, "# a new header\n\n" * BEFORE)
    @test isempty(shifted.changed) && isempty(shifted.removed)

    # One edited method inside a module is one changed expression of that module.
    edited = diff(BEFORE, replace(BEFORE, "f(x) = x + 1" => "f(x) = x + 2"))
    @test only(edited.changed)[1] == [:Demo]
    @test defined_name(only(edited.changed)[2]) === :f
    @test isempty(edited.removed)

    # A deleted method is removed and nothing is changed.
    deleted = diff(BEFORE, replace(BEFORE, "h(x) = x\n" => ""))
    @test isempty(deleted.changed)
    @test defined_name(only(deleted.removed)[2]) === :h

    # A method renamed by the edit is changed under its new name, and its old name is removed.
    renamed = diff(BEFORE, replace(BEFORE, "h(x) = x" => "k(x) = x"))
    @test defined_name(only(renamed.changed)[2]) === :k
    @test defined_name(only(renamed.removed)[2]) === :h
end

@testset "server dispatch" begin
    saves = Ref(0)
    status = ReactiveCompiler.rc_dispatch("status", saves)
    @test occursin(r"^ok world=\d+ saves=0 rss_kb=\d+$", status)
    @test ReactiveCompiler.rc_dispatch("quit", saves) == "ok"
    @test startswith(ReactiveCompiler.rc_dispatch("frobnicate", saves), "error unknown request")
    @test saves[] == 0
end
