# This file is a part of Julia. License is MIT: https://julialang.org/license

# Shrinking property test of the strict-mode piracy rule; test/strict.jl runs a fixed-seed version.
# Run it with a Julia built from this tree:
#   ./julia --project=test/strict_properties -e 'using Pkg; Pkg.instantiate(); include("test/strict_properties/runtests.jl")'

using Supposition, Test

include(joinpath(@__DIR__, "..", "strict_oracle.jl"))

"Draws choices from the current Supposition test case, so shrinking lowers them."
struct SuppositionPick end
(::SuppositionPick)(n::Int) = Data.produce!(Data.Integers(1, n))

@testset "the rule rejects every signature that matches foreign-only arguments" begin
    @check max_examples=5000 function rejects_foreign_matches(depth=Data.Integers(0, 3))
        sig = StrictOracle.random_signature(SuppositionPick(), depth)
        event!("signature", sig)
        StrictOracle.foreign_witness(sig) === nothing || Base._is_piracy(StrictOracle, sig)
    end
end
