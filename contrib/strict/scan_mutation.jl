include(joinpath(@__DIR__, "mutation.jl"))

seen = Base.IdSet{Method}()
tally = Dict{Symbol,Int}()
examples = Dict{Symbol,Vector{Method}}()
unreadable = 0
for mod in Base.loaded_modules_array(), n in names(mod; all=true, imported=false)
    if !isdefined(mod, n) || startswith(String(n), "#")
        continue
    end
    v = getglobal(mod, n)
    if !(v isa Function)
        continue
    end
    for m in methods(v).ms
        if m in seen
            continue
        end
        push!(seen, m)
        v = try
            verdict(m)
        catch
            global unreadable += 1
            continue
        end
        tally[v] = get(tally, v, 0) + 1
        push!(get!(examples, v, Method[]), m)
    end
end

total = sum(values(tally))
println("methods analyzed: ", total, "   unreadable (no lowered source): ", unreadable)
for k in (:ok, :writes_arg, :writes_global, :bang_but_clean)
    c = get(tally, k, 0)
    println("  ", rpad(k, 16), lpad(c, 6), "  ", round(100c / total; digits=1), "%")
end

println("\nwrites an argument, not named ! :")
for m in first(get(examples, :writes_arg, Method[]), 20)
    println("  ", m.module, ".", m.name, "  ", m.file, ":", m.line)
end
println("\nnamed ! but writes nothing:")
for m in first(get(examples, :bang_but_clean, Method[]), 12)
    println("  ", m.module, ".", m.name, "  ", m.file, ":", m.line)
end

println("\ndid it catch what the effects run flagged?")
for (f, tt) in ((mark, Tuple{IO}), (reset, Tuple{IOBuffer}), (Base.rand, Tuple{Random.TaskLocalRNG, Random.SamplerType{UInt64}}))
    try
        m = which(f, tt)
        println("  ", rpad(string(f, tt.parameters), 46), verdict(m))
    catch e
        println("  ", f, " -> ", sprint(showerror, e)[1:min(60,end)])
    end
end
