
module ClusterUtils

#=
function lookup(modname::Module, srchterm::Regex)
    vars = names(modname, true)
    indx = map((n)->ismatch(srchterm, string(n)), vars);
    vars[indx]
end


function filterpaths(dir, srch)
    srchr = Regex(srch)
    absdir = abspath(dir)
    fpths = readdir(absdir)
    matches = filter((name)->ismatch(srchr,name), fpths)
    map((nm)->absdir*"/"*nm, matches)
end

@doc """
Make a function that filters out strings matching the hostname of process 1.\n
""" ->
function makefiltermaster()
    master_node = strip(remotecall_fetch(readall, 1, `hostname`), '\n')
    function filtermaster(x)
        x != master_node
    end
    filtermaster
end


function describepids(pids; filterfn=(x)->true)

    # facts about the machines the processes run on
    machines = [strip(remotecall_fetch(readall, w, `hostname`), '\n') for w in pids]
    machine_names = sort!(collect(Set(machines)))
    machine_names = filter(filterfn, machine_names)
    num_machines = length(machine_names)

    # nominate a representative process for each machine, and define who it represents
    representative = zeros(Int64, num_machines)
    constituency = Dict()
    for (i,name) in enumerate(machine_names)
        constituency[i] = Int64[]
        for (j,machine) in enumerate(machines)
            if name==machine
                push!(constituency[i], pids[j])
                representative[i] = pids[j]
            end
        end
    end

    # assemble the groups of processes keyed by their representatives
    topo = Dict()
    for (i,p) in enumerate(representative)
        topo[p] = constituency[i]
    end

    topo
end

@doc """
Return information about the resources (pids) available to us grouped by the machine they are running on.\n
keyword argument: remote=0 (default) specifies remote machines; remote=1 the local machine; remote=2 all machines.\n 
length(topo) gives the number of unique nodes.\n
keys(topo) gives the id of a single process on each compute node.\n
values(topo) gives the ids of all processes running on each compute node.
""" ->
function describepids(; remote=0)
    pids = procs()
    if remote==0
        filterfn = makefiltermaster()
    elseif remote==1
        filtertrue = makefiltermaster()
        filterfn = (x)->!filtertrue(x)
    elseif remote==2
        filterfn=(x)->true
    end
    describepids(pids; filterfn=filterfn)
end

function localpids()
    topo = describepids(remote=1)
    topo[collect(keys(topo))[1]]
end
=#

macro timeit(reps, expr)
   quote
       mean([@elapsed $expr for i in 1:$reps])
   end
end

# REPRESENTATION OF SHARED ARRAYS THAT WORKS ON REMOTES

function getrepresentation(S)
    buf = IOBuffer()
    td = TextDisplay(buf)
    Base.Multimedia.display(td, S)
    str = takebuf_string(buf)
    return str
end

function Base.display(S::SharedArray)
    validpid = minimum(S.pids)
    repr = @fetchfrom validpid getrepresentation(S)
    print_with_color(:bold, repr)
end


# FOR BROADCASTING VARIABLES

function sendto(p::Int; args...)
    for (nm, val) in args
        @spawnat(p, eval(Main, Expr(:(=), nm, val)))
    end
end

function sendto(ps::Vector{Int}; args...)
    for p in ps
        sendto(p; args...)
    end
end

macro sendto(p, nm, val)
    return :( sendtosimple($p, $nm, $val) )
end


function sendtosimple(p::Int, nm, val; mod=Main)
    ref = @spawnat(p, eval(mod, Expr(:(=), nm, val)))
end


macro broadcast(nm, val)
    quote
    @sync for p in workers()
        @async sendtosimple(p, $nm, $val)
    end
    end
end

macro broadcastfrom(pid, nm, val)
    quote
        @spawnat $pid @broadcast $nm $val
    end
end

# SYNCHRONOUS DICTIONARIES

function __gettr(a) eval(a) end

function collectmsgsatpid(pid::Int64, msgname::Symbol; pidfuncsymbol=workers)
    wait(@spawnat pid begin 
        @sync for j in eval(pidfuncsymbol)() 
            val = remotecall_fetch(__gettr, j, Expr(:call, :getindex, msgname, j))
            #val = @fetchfrom j eval(Expr(:call, :getindex, msgname, j))
            @async eval(Expr(:call, :setindex!, msgname, val, j)) 
        end 
    end)
end

macro swapmsgs(msgname)
    quote 
    @sync for pid in workers()
         @async collectmsgsatpid(pid, $msgname)
    end   
    end 
end

#@broadcast :somemsg Dict([k => 0 for k in workers()])
#[@spawnat k somemsg[k] = k for k in workers()]
#@fetchfrom remotes[1] somemsg

function collectrefs(doable::Expr; pidfunc=workers)
    results = Dict()
    @sync for k in pidfunc()
        @async results[k] = @spawnat k eval(doable)
    end
    results
end
#somerefs = collectrefs(:(somemsg[myid()]))

function quothfetchxfromn(n, x) 
    quote @fetchfrom $n $x end 
end

function quothfetchxsubnfromn(n, x) 
    quote @fetchfrom $n eval(Expr(:call, :getindex, $x, $n)) end 
end

end
