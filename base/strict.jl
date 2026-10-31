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
    home = _root_module(e.mod)
    join(io, unique(m for m in _type_owners!(Module[], e.sig) if _root_module(m) !== home), ", ")
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
    _is_owned(home, T, exact=false) -> Bool

Whether `T` excludes every value whose type mentions only types declared outside
`home`. As in Aqua.jl, a type is owned when its name or one of its parameters is.
A `Union` is owned only when every member is; a `Vararg` only when its length is
fixed and positive, since `Vararg{T}` also matches zero arguments.

`exact` marks an invariant parameter (anything below a non-`Tuple` type's parameter):
a matching value's type contains that parameter verbatim, so mentioning one owned type
suffices there. A `TypeVar` ranges over its bound, so it is never exact.
"""
function _is_owned(home::Module, @nospecialize(T), exact::Bool=false)
    if T isa DataType
        if _root_module(T.name.module) === home
            return true
        end
        inner = exact || T.name !== Tuple.name
        for p in T.parameters
            if _is_owned(home, p, inner)
                return true
            end
        end
        return false
    elseif T isa UnionAll
        return _is_owned(home, T.body, exact)
    elseif T isa Union
        # A free typevar can absorb the owned member: `Union{S,Widget}` is `Any` at `S = Any`.
        if exact && !has_free_typevars(T)
            return _is_owned(home, T.a, true) || _is_owned(home, T.b, true)
        end
        return _is_owned(home, T.a) && _is_owned(home, T.b)
    elseif T isa TypeVar
        return _is_owned(home, T.ub)
    elseif T isa Core.TypeofVararg
        # An unbounded `Vararg` is part of the exact type; a typevar length can still be 0.
        if exact && !(isdefined(T, :N) && T.N isa TypeVar)
            return isdefined(T, :T) && _is_owned(home, T.T, true)
        end
        return isdefined(T, :N) && T.N isa Int && T.N > 0 && _is_owned(home, T.T)
    else
        return _is_owned(home, typeof(T))  # a value used as a type parameter
    end
end

"""
    _is_piracy(mod, sig) -> Bool

Whether a method with signature `sig` defined in `mod` can apply to arguments whose
types the module's package does not own. `sig` includes the callee at position 1,
so a module always owns methods of its own functions.
"""
function _is_piracy(mod::Module, @nospecialize(sig))
    home = _root_module(mod)
    for p in (unwrap_unionall(sig)::DataType).parameters
        if _is_owned(home, p)
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
