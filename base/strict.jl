# Strict-mode definition checks. Spliced into base/ as part of Base.

"""
    StrictModeError(mod, sig)

A method definition in `mod` violated a rule enforced by `@compiler_options strict=true`.
"""
struct StrictModeError <: Exception
    mod::Module
    sig::Any
end

function showerror(io::IO, e::StrictModeError)
    print(io, "StrictModeError: type piracy in strict module ", e.mod, "\n  ")
    show(io, e.sig)
    print(io, "\nowns none of: ")
    join(io, unique!(_type_owners!(Module[], e.sig)), ", ")
    print(io, "\nDefine this method in a module that owns the function or one of the ",
              "argument types, or drop `strict=true`.")
end

"""
    _root_module(m::Module) -> Module

Top-level module `m` belongs to: walks parents while the next one is not `Main`.
Maps a package's submodules onto the package itself.
"""
function _root_module(m::Module)
    p = parentmodule(m)
    while p !== m && p !== Main
        m = p
        p = parentmodule(m)
    end
    return m
end

"""
    _type_owners!(out, T) -> out

Append every module that declares a named type reachable from `T`, descending
through parameters, unions, and typevar bounds so that `Type{MyType}` and
`Vector{MyType}` both credit `MyType`'s module.
"""
function _type_owners!(out::AbstractVector{Module}, @nospecialize(T))
    if T isa DataType
        push!(out, T.name.module)
        for p in T.parameters
            _type_owners!(out, p)
        end
    elseif T isa UnionAll
        _type_owners!(out, T.var)
        _type_owners!(out, T.body)
    elseif T isa Union
        _type_owners!(out, T.a)
        _type_owners!(out, T.b)
    elseif T isa TypeVar
        _type_owners!(out, T.ub)
    elseif T isa Core.TypeofVararg
        if isdefined(T, :T)
            _type_owners!(out, T.T)
        end
    end
    return out
end

"""
    _is_piracy(mod, sig) -> Bool

Whether defining a method with signature `sig` in `mod` extends something the
module's package does not own. `sig` includes the callee at position 1, so a
module always owns methods of its own functions.
"""
function _is_piracy(mod::Module, @nospecialize(sig))
    home = _root_module(mod)
    for owner in _type_owners!(Module[], sig)
        if _root_module(owner) === home
            return false
        end
    end
    return true
end

"""
    _check_method_definition(mod, sig)

Called from `jl_method_def` for modules built with `strict=true`.
"""
function _check_method_definition(mod::Module, @nospecialize(sig))
    if _is_piracy(mod, sig)
        throw(StrictModeError(mod, sig))
    end
    return nothing
end
