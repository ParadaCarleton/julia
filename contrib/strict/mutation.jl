# Decides from lowered IR alone whether a method writes through one of its own
# arguments, or to a global. Callees are summarized recursively; whatever the walk
# cannot follow makes the answer `:unknown`, never `:clean`.

"""Origin index of memory reachable from a global; argument slot `i` is origin `i`."""
const GLOBAL = 0

"""Call depth past which a callee counts as opaque."""
const MAX_DEPTH = 8

"""Dispatch candidates past which an untyped call counts as opaque."""
const MAX_TARGETS = 4

"""Generic functions whose result usually points into their first argument."""
const ACCESSORS = (:getproperty, :getindex, :view, :first, :last, :only, :parent, :values)

"""
Effects over origins. `writes` may be written through, `stores` may be stored into
reachable memory, the result may alias `returns`, `opaque` means not followed.
"""
struct Summary
    writes::BitSet
    stores::BitSet
    returns::BitSet
    opaque::Bool
end

Summary(; writes::BitSet = BitSet(), stores::BitSet = BitSet(), returns::BitSet = BitSet(),
        opaque::Bool = false)::Summary = Summary(writes, stores, returns, opaque)

opaque_summary()::Summary = Summary(; opaque = true)

const I = Core.Intrinsics
"""Builtins whose result holds no memory of their arguments."""
const PURE_BUILTINS = (Core.:(<:), Core.:(===), Core._svec_len, Core._typevar, Core.apply_type,
    Core.fieldtype, Core.isa, Core.isdefined, Core.isdefinedglobal, Core.memoryref_isassigned,
    Core.memoryrefoffset, Core.nfields, Core.sizeof, Core.typeof, Core.memorynew,
    Core.current_scope, Core.donotdelete, Core.throw, Core.throw_methoderror,
    Core._compute_sparams, Core.get_binding_type, Core.applicable, Core._equiv_typedef)
"""Builtins whose result may alias any argument."""
const READ_BUILTINS = (Core.getfield, Core.getproperty, Core.memoryrefget, Core.memoryrefnew,
    Core.typeassert, Core.tuple, Core.svec, Core._svec_ref, Core.ifelse, Core.compilerbarrier,
    Core._expr, I.bitcast, I.add_ptr, I.sub_ptr, I.pointerref, I.atomic_pointerref)
"""Builtins that write through their first argument and store the rest."""
const FIELD_WRITES = (Core.setfield!, Core.setproperty!, Core.setfieldonce!, Core.replacefield!,
    Core.swapfield!, Core.memoryrefset!, Core.memoryrefsetonce!, Core.memoryrefreplace!,
    Core.memoryrefswap!, I.pointerset, I.atomic_pointerset, I.atomic_pointerswap,
    I.atomic_pointerreplace)
"""Builtins that write a global binding or type definition."""
const GLOBAL_WRITES = (Core.setglobal!, Core.setglobalonce!, Core.replaceglobal!,
    Core.swapglobal!, Core.declare_const, Core.declare_global, Core._setsuper!, Core._typebody!,
    Core._abstracttype, Core._primitivetype, Core._structtype, Core._defaultctors, Core._import,
    Core._using)
"""Intrinsics that are opaque: they run user code or reach unknown memory."""
const OPAQUE_INTRINSICS = (I.llvmcall, I.atomic_pointermodify)
"""Intrinsics that dereference their first argument."""
const POINTERS = (I.pointerref, I.atomic_pointerref, I.pointerset, I.atomic_pointerset,
    I.atomic_pointerswap, I.atomic_pointerreplace)

"""Lowered expression heads that define globals."""
const DEFINITIONS = (:method, :const, :global, :globaldecl, :thunk, :toplevel, :export, :public,
    :module, :using, :import)
"""Lowered expression heads with no memory effect and no aliasing result."""
const INERT_HEADS = (:leave, :pop_exception, :gc_preserve_begin, :gc_preserve_end, :meta,
    :inbounds, :loopinfo, :code_coverage_effect, :latestworld, :boundscheck, :static_parameter,
    :isdefined, :copyast, :aliasscope, :popaliasscope, :cfunction, :inline, :noinline,
    :throw_undef_if_not, :undefcheck)

is_bang(name::Symbol)::Bool = endswith(String(name), "!") && name !== :!

"""Values with no writable memory a caller could observe."""
inert(x::Any)::Bool = isbits(x) || x isa Union{Module, Type, Symbol, String}

"""Origins of a value with no tracked source: none if inert, else global memory."""
function literal_origins(x::Any)::BitSet
    if inert(x)
        return BitSet()
    end
    return BitSet(GLOBAL)
end

"""One method body under analysis; `ssa` and `heap` grow monotonically to a fixpoint."""
struct Frame{C <: AbstractVector, S <: Tuple}
    code::C
    nargs::Int
    ssa::Vector{BitSet}
    heap::BitSet
    memo::IdDict{Method, Summary}
    stack::S
end

"""Origins a lowered operand may alias, given the slot origins `slots`."""
function origins(x::Any, frame::Frame, slots::AbstractVector{BitSet})::BitSet
    if x isa Core.SlotNumber
        return slots[x.id]
    elseif x isa Core.SSAValue
        return frame.ssa[x.id]
    elseif x isa Core.Argument
        return BitSet(x.n)
    elseif x isa GlobalRef
        if isconst(x)
            return literal_origins(getglobal(x.mod, x.name))
        end
        return BitSet(GLOBAL)
    elseif x isa QuoteNode
        return literal_origins(x.value)
    end
    return literal_origins(x)
end

"""`Some(v)` when operand `x` always evaluates to `v`, else `nothing`."""
function constant(x::Any, code::AbstractVector)::Union{Nothing, Some}
    if x isa Core.SSAValue
        return constant(code[x.id], code)
    elseif x isa GlobalRef
        if isconst(x)
            return Some(getglobal(x.mod, x.name))
        end
        return nothing
    elseif x isa QuoteNode
        return Some(x.value)
    elseif x isa Union{Core.SlotNumber, Core.Argument}
        return nothing
    elseif !(x isa Expr)
        return Some(x)
    elseif x.head !== :call
        return nothing
    end
    consts = [constant(a, code) for a in x.args]
    if any(isnothing, consts)
        return nothing
    end
    f, vals = something(first(consts)), [something(c) for c in Iterators.drop(consts, 1)]
    foldable = f === Core.apply_type ||
        (f === getproperty && first(vals) isa Module && isconst(first(vals), last(vals)))
    if !foldable
        return nothing
    end
    try
        return Some(f(vals...))
    catch
        return nothing
    end
end

"""Inferred-free type of operand `x`: its constant's type, else `Any`."""
function operand_type(x::Any, code::AbstractVector)::Type
    c = constant(x, code)
    if c === nothing
        return Any
    end
    return Core.Typeof(something(c))
end

"""Union of `sets`, as a fresh set."""
union_all(sets::Any)::BitSet = union(BitSet(), sets...)

"""Caller origins for callee positions `positions` of method `m`, given per-argument `argsets`."""
function caller_origins(positions::BitSet, m::Method, argsets::AbstractVector{BitSet})::BitSet
    out = BitSet()
    for p in positions
        if p == GLOBAL
            union!(out, GLOBAL)
        elseif m.isva && p == m.nargs
            union!(out, union_all(Iterators.drop(argsets, p - 1)))
        elseif p <= length(argsets)
            union!(out, argsets[p])
        end
    end
    return out
end

"""
Effect of a generic call `args` (callee first): the union over every method it may hit.
Past `MAX_TARGETS` it is opaque, but a `!` callee still reports a write to its first argument.
"""
function generic_call(f::Any, args::AbstractVector, argsets::AbstractVector{BitSet},
                      frame::Frame)::Summary
    tt = Tuple{(operand_type(a, frame.code) for a in Iterators.drop(args, 1))...}
    ms = try
        methods(f, tt).ms
    catch
        return opaque_summary()
    end
    writes, stores, returns = BitSet(), BitSet(), BitSet()
    if length(ms) > MAX_TARGETS
        # Guess by name so writes behind an opaque call still surface as writes.
        named = f isa Function && length(argsets) > 1
        if named && is_bang(nameof(f))
            union!(writes, argsets[2])
        end
        if named && nameof(f) in ACCESSORS
            union!(returns, argsets[2])
        end
        return Summary(writes, stores, returns, true)
    end
    opaque = false
    for m in ms
        s = method_summary(m, frame.memo, frame.stack)
        opaque |= s.opaque
        union!(writes, caller_origins(s.writes, m, argsets))
        union!(stores, caller_origins(s.stores, m, argsets))
        union!(returns, caller_origins(s.returns, m, argsets))
    end
    return Summary(writes, stores, returns, opaque)
end

"""Effect of a `:call` expression with operands `args`, callee first."""
function call_effect(args::AbstractVector, frame::Frame, slots::AbstractVector{BitSet})::Summary
    c = constant(first(args), frame.code)
    if c === nothing
        return opaque_summary()
    end
    f = something(c)
    argsets = [origins(a, frame, slots) for a in args]
    rest = Iterators.drop(argsets, 1)
    if !(f isa Core.Builtin)
        return generic_call(f, args, argsets, frame)
    elseif f in OPAQUE_INTRINSICS
        return opaque_summary()
    elseif f in POINTERS && isempty(argsets[2])
        # A pointer without provenance may address any memory.
        if f in FIELD_WRITES
            return opaque_summary()
        end
        return Summary(; returns = BitSet(GLOBAL))
    elseif f === Core.getglobal || f === I.cglobal
        return Summary(; returns = BitSet(GLOBAL))
    elseif f in READ_BUILTINS
        return Summary(; returns = union_all(rest))
    elseif f in FIELD_WRITES
        return Summary(; writes = copy(argsets[2]), stores = union_all(Iterators.drop(rest, 1)),
                       returns = union_all(rest))
    elseif f in GLOBAL_WRITES
        return Summary(; writes = BitSet(GLOBAL), stores = union_all(rest), returns = BitSet(GLOBAL))
    elseif f in PURE_BUILTINS || f isa Core.IntrinsicFunction
        return Summary()
    end
    return opaque_summary()
end

"""Whether a `ccall` argument or result of declared type `t` can carry a reference to memory."""
carries_memory(t::Any)::Bool = !(t isa Type && isbitstype(t)) || t <: Ptr

"""
Effect of a `:foreigncall`. C code may touch any memory it is handed, so a handed
reference, or any pointer, makes it opaque. C-side state is outside the analysis.
"""
function foreigncall_effect(ex::Expr, frame::Frame, slots::AbstractVector{BitSet})::Summary
    for (t, a) in zip(ex.args[3], Iterators.drop(ex.args, 5))
        if carries_memory(t) && (!isempty(origins(a, frame, slots)) || (t isa Type && t <: Ptr))
            return opaque_summary()
        end
    end
    if carries_memory(ex.args[2])
        return Summary(; returns = BitSet(GLOBAL))
    end
    return Summary()
end

"""Effect of evaluating one lowered right-hand side."""
function effect(rhs::Any, frame::Frame, slots::AbstractVector{BitSet})::Summary
    if !(rhs isa Expr)
        return Summary(; returns = origins(rhs, frame, slots))
    end
    head = rhs.head
    if head === :call || head === :foreigncall
        s = if head === :call
            call_effect(rhs.args, frame, slots)
        else
            foreigncall_effect(rhs, frame, slots)
        end
        # The result may be read from memory holding anything stored so far.
        return Summary(s.writes, s.stores, union(s.returns, frame.heap), s.opaque)
    elseif head === :new || head === :splatnew
        return Summary(; returns = union_all(origins(a, frame, slots) for a in rhs.args))
    elseif head === :the_exception
        return Summary(; returns = union(BitSet(0:frame.nargs), frame.heap))
    elseif head in DEFINITIONS
        return Summary(; writes = BitSet(GLOBAL),
                       stores = union_all(origins(a, frame, slots) for a in rhs.args))
    elseif head in INERT_HEADS
        return Summary()
    end
    return opaque_summary()
end

"""Statement indices control may reach after `stmt` at `pc`, exceptions aside."""
function successors(stmt::Any, pc::Integer, n::Integer)::Vector{Int}
    if stmt isa Core.GotoNode
        return [stmt.label]
    elseif stmt isa Core.GotoIfNot
        return filter(<=(n), [pc + 1, stmt.dest])
    elseif stmt isa Core.ReturnNode
        return Int[]
    end
    return filter(<=(n), [pc + 1])
end

"""`union!(dest, src)`; whether `dest` grew."""
function grow!(dest::BitSet, src::BitSet)::Bool
    before = length(dest)
    union!(dest, src)
    return length(dest) != before
end

"""Join slot origins `slots` into the entry state of `pc`; whether it grew."""
function flow!(states::AbstractMatrix{BitSet}, reached::AbstractVector{Bool}, pc::Integer,
               slots::AbstractVector{BitSet})::Bool
    first_visit = !reached[pc]
    reached[pc] = true
    grew = false
    for (entry, incoming) in zip(view(states, :, pc), slots)
        grew |= grow!(entry, incoming)
    end
    return first_visit || grew
end

"""
    summarize(ci, nargs, memo, stack) -> Summary

Flow-sensitive over slots, so reassignment replaces a slot's origins. Memory is one
abstract heap per method: anything stored anywhere may come back from any read.
"""
function summarize(ci::Core.CodeInfo, nargs::Integer, memo::IdDict{Method, Summary},
                   stack::Tuple)::Summary
    code = ci.code
    n = length(code)
    nslots = length(ci.slotnames)
    states = [BitSet() for _ in 1:nslots, _ in 1:n]
    for (slot, entry) in zip(1:min(nargs, nslots), view(states, :, 1))
        union!(entry, slot)
    end
    reached = falses(n)
    reached[1] = true
    catches = [s.catch_dest for s in code if s isa Core.EnterNode && s.catch_dest > 0]
    frame = Frame(code, Int(nargs), [BitSet() for _ in code], BitSet(), memo, stack)
    writes, returns = BitSet(), BitSet()
    opaque = false
    changed = true
    while changed
        changed = false
        for (pc, stmt) in pairs(code)
            if !reached[pc]
                continue
            end
            slots = copy.(view(states, :, pc))
            target, rhs = nothing, stmt
            if stmt isa Expr && stmt.head === :(=)
                target, rhs = stmt.args[1], stmt.args[2]
            end
            e = effect(rhs, frame, slots)
            union!(writes, e.writes)
            changed |= grow!(frame.heap, e.stores)
            opaque |= e.opaque
            if target isa Core.SlotNumber
                slots[target.id] = copy(e.returns)
            elseif target isa GlobalRef
                union!(writes, GLOBAL)
                changed |= grow!(frame.heap, e.returns)
            elseif target === nothing
                changed |= grow!(frame.ssa[pc], e.returns)
            else
                opaque = true
            end
            if stmt isa Core.NewvarNode
                slots[stmt.slot.id] = BitSet()
            elseif stmt isa Core.ReturnNode && isdefined(stmt, :val)
                union!(returns, origins(stmt.val, frame, slots))
            end
            for dest in Iterators.flatten((successors(stmt, pc, n), catches))
                changed |= flow!(states, reached, dest, slots)
            end
        end
    end
    return Summary(writes, frame.heap, returns, opaque)
end

"""Lowered source of `m`, or `nothing` when generated or unavailable."""
function lowered_source(m::Method)::Union{Nothing, Core.CodeInfo}
    if Base.hasgenerator(m)
        return nothing
    end
    try
        return Base.uncompressed_ast(m)
    catch
        return nothing
    end
end

"""Summary of method `m`, memoized; recursion, depth, and missing source make it opaque."""
function method_summary(m::Method, memo::IdDict{Method, Summary}, stack::Tuple)::Summary
    if haskey(memo, m)
        return memo[m]
    elseif m in stack || length(stack) >= MAX_DEPTH
        return opaque_summary()
    end
    ci = lowered_source(m)
    # ponytail: summaries cut by recursion or depth stay opaque; precise needs an SCC fixpoint.
    s = opaque_summary()
    if ci !== nothing
        s = summarize(ci, m.nargs, memo, (stack..., m))
    end
    memo[m] = s
    return s
end

"""Verdict for a summary: a known write first, then whether anything went unfollowed."""
function kind(s::Summary)::Symbol
    if GLOBAL in s.writes
        return :writes_global
    elseif !isempty(s.writes)
        return :writes_arg
    elseif s.opaque
        return :unknown
    end
    return :clean
end

"""
    mutation_kind(ci, nargs[, memo]) -> Symbol

`:writes_global`, `:writes_arg`, `:unknown`, or `:clean`. Aliasing is over-approximated,
so a write report may be spurious; `:clean` means no write is reachable.
"""
mutation_kind(ci::Core.CodeInfo, nargs::Integer,
              memo::IdDict{Method, Summary} = IdDict{Method, Summary}())::Symbol =
    kind(summarize(ci, nargs, memo, ()))

"""Whether `m`'s name matches what its body does."""
function verdict(m::Method, memo::IdDict{Method, Summary} = IdDict{Method, Summary}())::Symbol
    k = kind(method_summary(m, memo, ()))
    if k === :clean
        if is_bang(m.name)
            return :bang_but_clean
        end
        return :ok
    elseif is_bang(m.name)
        return :ok
    end
    return k
end
