# Regression tests for contrib/vendor_stdlibs.jl. Usage: julia contrib/test_vendor_stdlibs.jl
using Test

include(joinpath(@__DIR__, "vendor_stdlibs.jl"))

const Table = Dict{String, Dict{String, String}}
const REPO = "https://example.org/Pkg.jl"
const SOURCES = Table(
    "Tagged" => Dict("repo" => REPO, "ref" => "release"),
    "Branch" => Dict("repo" => REPO, "ref" => "dev"),
    "Local" => Dict("path" => "../Local"),
)
# What vendor! records: the requested ref beside the tag or branch it resolved to.
const LOCKS = Table(
    "Tagged" => Dict("repo" => REPO, "requested" => "release", "ref" => "v1.2.3", "commit" => "a"),
    "Branch" => Dict("repo" => REPO, "requested" => "dev", "ref" => "dev", "commit" => "b"),
)

@testset "check_lock" begin
    @test check_lock(SOURCES, LOCKS) === nothing

    @testset "a changed ref is stale" begin
        sources = merge(SOURCES, Table("Branch" => Dict("repo" => REPO, "ref" => "main")))
        @test_throws "for [\"Branch\"]" check_lock(sources, LOCKS)
    end

    @testset "a changed repository is stale" begin
        sources = merge(SOURCES, Table("Tagged" => Dict("repo" => "https://example.org/Fork.jl", "ref" => "release")))
        @test_throws "for [\"Tagged\"]" check_lock(sources, LOCKS)
    end

    @testset "release is not the tag it resolved to" begin
        sources = merge(SOURCES, Table("Tagged" => Dict("repo" => REPO, "ref" => "v1.2.3")))
        @test_throws "for [\"Tagged\"]" check_lock(sources, LOCKS)
    end

    @testset "a lock without the requested ref is stale" begin
        locks = merge(LOCKS, Table("Branch" => Dict("repo" => REPO, "ref" => "dev", "commit" => "b")))
        @test_throws "for [\"Branch\"]" check_lock(SOURCES, locks)
    end

    @testset "a missing or extra package is reported by name" begin
        @test_throws "pins [\"Branch\"]" check_lock(SOURCES, Table("Branch" => LOCKS["Branch"]))
        @test_throws "pins [\"Branch\", \"Gone\", \"Tagged\"]" check_lock(SOURCES, merge(LOCKS, Table("Gone" => LOCKS["Branch"])))
    end
end

@testset "check_links" begin
    sources = Table("Local" => Dict("path" => "../Local"), "Branch" => SOURCES["Branch"])
    """A temp `stdlib/` dir whose `Local` symlink points at `target`, beside an existing `Local/`."""
    function layout(target::AbstractString; made::Bool = true)::String
        root = mktempdir()
        stdlib_dir = mkpath(joinpath(root, "stdlib"))
        mkpath(joinpath(root, "Local"))
        if made
            symlink(target, joinpath(stdlib_dir, "Local"))
        end
        return stdlib_dir
    end

    @test check_links(sources, layout("../Local")) === nothing
    @test_throws "links to ../Other, not ../Local" check_links(sources, layout("../Other"))
    @test_throws "not a symlink" check_links(sources, layout("../Local"; made = false))

    @testset "a configured path that does not exist" begin
        gone = Table("Local" => Dict("path" => "../DoesNotExist"))
        @test_throws "does not exist" check_links(gone, layout("../DoesNotExist"))
    end
end
