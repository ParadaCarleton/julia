# This file is a part of Julia. License is MIT: https://julialang.org/license

using InteractiveUtils: @activate

# The stdlib Compiler serves packages that depend on it; tests activate only a project's own Compiler.
if let pkg = Base.identify_package("Compiler")
        pkg !== nothing && !startswith(Base.locate_package(pkg), Sys.STDLIB)
    end && !isdefined(Main, :__custom_compiler_active)
    Base.eval(Main, :(__custom_compiler_active=true))
    @activate Compiler
end

if !@isdefined(Compiler)
    if Base.REFLECTION_COMPILER[] === nothing
        using Base.Compiler: Compiler
    else
        const Compiler = Base.REFLECTION_COMPILER[]
    end
end
