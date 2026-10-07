# Decides from lowered IR alone whether a method writes through one of its own
# arguments, or to a global. No inference, so every method gets a definite answer.

"""
Calls whose result still points into the memory of their first argument. `getindex`
is absent because `T[]` lowers to it, which constructs rather than accesses.
"""
const ACCESSORS = (:getfield, :getproperty, :arrayref, :memoryrefget, :memoryref)

"""Calls that write through their first argument regardless of name."""
const PRIMITIVE_WRITES = (:setfield!, :memoryrefset!, :modifyfield!, :replacefield!, :swapfield!)

is_bang(name::Symbol) = endswith(String(name), "!") && name !== :!

"""Name of the function a call statement dispatches to, or `nothing` if opaque."""
function callee(x, code)
    if x isa Core.SSAValue
        x = code[x.id]
    end
    if x isa GlobalRef
        return x.name
    end
    if x isa QuoteNode && x.value isa Function
        return nameof(x.value)
    end
    return nothing
end

"""
    mutation_kind(ci, nargs) -> Symbol

`:writes_global`, `:writes_arg`, or `:clean`. A value carries an origin when it is
an argument slot or a global binding, a copy of one, or an accessor reaching into one.
"""
function mutation_kind(ci, nargs)
    code = ci.code
    nslots = length(ci.slotnames)
    ssa_arg, ssa_glob = falses(length(code)), falses(length(code))
    slot_arg, slot_glob = falses(nslots), falses(nslots)
    for i in 1:min(nargs, nslots)
        slot_arg[i] = true
    end

    from_arg(x) = begin
        if x isa Core.SSAValue
            return ssa_arg[x.id]
        elseif x isa Core.SlotNumber
            return slot_arg[x.id]
        end
        return false
    end
    from_glob(x) = begin
        if x isa GlobalRef
            return true
        elseif x isa Core.SSAValue
            return ssa_glob[x.id]
        elseif x isa Core.SlotNumber
            return slot_glob[x.id]
        end
        return false
    end

    writes_global, writes_arg = false, false
    # Slots are not SSA and gotos carry values backwards, so run to fixpoint.
    changed = true
    while changed
        changed = false
        for (i, stmt) in enumerate(code)
            rhs, target = stmt, nothing
            if stmt isa Expr && stmt.head === :(=)
                target, rhs = stmt.args[1], stmt.args[2]
            end

            fa, fg = false, false
            if rhs isa Core.SlotNumber || rhs isa Core.SSAValue || rhs isa GlobalRef
                fa, fg = from_arg(rhs), from_glob(rhs)
            elseif rhs isa Expr && rhs.head === :call
                name = callee(rhs.args[1], code)
                argv = @view rhs.args[2:end]
                if name in ACCESSORS && !isempty(argv)
                    fa, fg = from_arg(argv[1]), from_glob(argv[1])
                end
                if name === :setglobal!
                    writes_global = true
                end
                writes_here = name in PRIMITIVE_WRITES
                if name !== nothing && is_bang(name)
                    writes_here = true
                end
                if writes_here && !isempty(argv)
                    if from_arg(argv[1])
                        writes_arg = true
                    end
                    if from_glob(argv[1])
                        writes_global = true
                    end
                end
            end

            for (flows, sl, sa) in ((fa, slot_arg, ssa_arg), (fg, slot_glob, ssa_glob))
                if !flows
                    continue
                end
                if target isa Core.SlotNumber && !sl[target.id]
                    sl[target.id] = true
                    changed = true
                elseif target === nothing && !sa[i]
                    sa[i] = true
                    changed = true
                end
            end
        end
    end

    if writes_global
        return :writes_global
    elseif writes_arg
        return :writes_arg
    end
    return :clean
end

"""Whether `m`'s name matches what its body does."""
function verdict(m)
    kind = mutation_kind(Base.uncompressed_ast(m), m.nargs)
    if kind === :clean
        if is_bang(m.name)
            return :bang_but_clean
        end
        return :ok
    end
    if is_bang(m.name)
        return :ok
    end
    return kind
end
