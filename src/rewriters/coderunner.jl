# # Code execution
#
# For documentation sites and blog articles, including code snippets
# in your documents is a great way to connect the theoretical concepts
# with the application. Here we implement [`ExecuteCode`](#), a [`Rewriter`](#)
# that executes marked code blocks and includes the output in the document.
#
# You can use the rewriter by passing it to the [`Project`](#) constructor:
# ```julia
# project = Project(dir, [ExecuteCode()])
# ```
#
# Executing code blocks takes a lot of time, so to give a pleasant interactive
# document creation experience we should make code execution incremental. If a document
# changes, we'll only rerun the code blocks that changed and the ones following them
# (since they may depend on the state of the previous blocks).
#
# Another consideration is that groups of code blocks should be isolated so that they
# don't affect the execution of other groups. We'll assume by default that all code
# blocks marked executable in one document are a group but give the ability to specify
# a different group where needed.
#
#
# ## Cached code execution
#
# Let's focus on the cached code execution before integrating it into the document
# processing system.
#
# We'll implement [`runblockscached`](#), a function that runs a collection of code blocks
# inside a scope and captures the printed output as well as the result of the last code
# line. It caches the results so that only blocks that change have to be rerun.
#
# The cache holds the code, outputs and results for a group of code blocks, as well as
# a module that the code is evaluated in.

mutable struct RunCache
    blocks::Vector{String}
    outputs::Vector{Any}
    results::Vector{Any}
    module_::Module
end

RunCache() = RunCache(String[], [], [], Module())
RunCache(s::Symbol) = RunCache(String[], [], [], Module(s))
Base.show(io::IO, cache::RunCache) = print(io, "RunCache($(nameof(cache.module_)))")

# In case we don't have the result of a block cached, we capture output and result with
# [`runblock`](#).

function runblock(m::Module, codeblock)
    c = IOCapture.capture(rethrow=InterruptException, color=true) do
        Base.include_string(m, codeblock)
    end
    return c.output, c.value
end

# We put these two together for [`runblockscached`](#):

function runblockscached(cache::RunCache, blocks)
    outputs = []
    results = []
    updated = false
    for (i, block) in enumerate(blocks)
        oldblock = length(cache.blocks) >= i ? cache.blocks[i] : nothing
        if !updated && oldblock == block
            output, result = cache.outputs[i], cache.results[i]
        else
            output, result = runblock(cache.module_, block)
            updated = true
        end
        push!(outputs, output)
        push!(results, result)
    end
    return RunCache(blocks, outputs, results, cache.module_)
end


## Rewriter
#
# The rewriter for code execution finds code blocks matching a selector,
# groups them, executes them and includes the output and result in a document.
# We also want to warn when an error is thrown which is useful when changes in
# source code break examples.

# The default selector mimicks the behavior of Publish.jl. "pre[lang="julia" cell]
const PUBLISH_CODEBLOCK_SELECTOR = SelectTag(:codeblock) & SelectAttrEq(:lang, "julia") & SelectHasAttr(:cell)

Base.@kwdef struct ExecuteCode <: Rewriter
    # Execution caches for each group of code blocks
    caches::Dict{Symbol, RunCache} = Dict{Symbol, RunCache}()
    # Whether to log when a code block throws an error
    warnonerror::Bool = true
    # Selector for code blocks to execute
    codeblocksel::Selector = PUBLISH_CODEBLOCK_SELECTOR
    # Function to get a group from a selected block
    groupfn = x -> get(attributes(x), :cell, "main")
    # Lock to avoid crashes
    lock::ReentrantLock = ReentrantLock()
end

# The rewriter acts on the document tree with [´rewritedoc`](#).

function rewritedoc(executecode::ExecuteCode, p, doc)
    blocks = collect(select(doc, executecode.codeblocksel))
    codes = gettext.(blocks)

    groupids = [creategroupid(p, executecode.groupfn(block)) for block in blocks]
    outputs, results = lock(executecode.lock) do
        executegrouped!(executecode.caches, codes, groupids)
    end

    if executecode.warnonerror
        for (i, result) in enumerate(results)
            if result isa LoadError
                @warn "Got evaluation error in code block:\n\n$(codes[i])\n" error=result.error doc=p block=i line=result.line
            end
        end
    end


    newblocks = Node[]
    for (i, block) in enumerate(blocks)
        chs = Node[Node(:codeinput, block)]

        includeoutput = get(attributes(block), :output, "true") == "true"
        if includeoutput && !isempty(outputs[i])
            node_output = Node(:codeoutput, Node(:codeblock, [Leaf(ANSI(outputs[i]))]))
            push!(chs, node_output)
        end

        include_result = get(attributes(block), :result, "true") == "true"
        if include_result && !isnothing(results[i])
            node_result = if hasrichdisplay(results[i])
                Node(:coderesult, results[i])
            else
                Node(:coderesult, Node(:codeblock, ANSI(results[i])))
            end
            push!(chs, node_result)
        end

        push!(newblocks, Node(:codecell, chs, attributes(block)))
    end

    return replacemany(doc, newblocks, executecode.codeblocksel)
end

function hasrichdisplay(x)
    return any(showable(m, x) for m in [
        MIME"text/html"(),
        MIME"text/latex"(),
        MIME"image/svg+xml"(),
        MIME"image/png"(),
        MIME"image/jpeg"(),
    ])
end

# We use a helper for executing the code blocks in groups and restoring the ordering
# afterwards:

function executegrouped!(caches, codes, groupids)
    is = []
    codesgrouped = Dict{Symbol, Vector{String}}()

    for (i, (gid, code)) in enumerate(zip(groupids, codes))
        groupcodes = get!(codesgrouped, gid, String[])
        push!(groupcodes, code)
        push!(is, (gid, length(groupcodes)))
    end

    for gid in keys(codesgrouped)
        cache = get!(caches, gid, RunCache(gid))
        caches[gid] = runblockscached(cache, codes)
    end

    outputs = [caches[gid].outputs[i] for (gid, i) in is]
    results = [caches[gid].results[i] for (gid, i) in is]

    return outputs, results
end

creategroupid(path, groupname) = Symbol("$(CM.slugify(string(path)))_$groupname")


# Resetting the rewriter clears the caches:

function reset!(executecode::ExecuteCode)
    foreach(k -> delete!(executecode.caches, k), keys(executecode.caches))
    return
end

# ## Tests

@testset "ExecuteCode [rewriter]" begin
    @testset "Basic" begin
        rewriter = ExecuteCode(codeblocksel = SelectTag(:codeblock))
        doc = Node(:md, Node(:codeblock, "1 + 1"))
        @test Pollen.rewritedoc(rewriter, "path", doc) == Node(:md, Node(:codecell,
            Node(:codeinput, Node(:codeblock, "1 + 1")),
            Node(:coderesult, 2)
        ))
    end
    @testset "Output" begin
        rewriter = ExecuteCode(codeblocksel = SelectTag(:codeblock))
        doc = Node(:md, Node(:codeblock, "print(\"hi\")"))
        @test Pollen.rewritedoc(rewriter, "path", doc) == Node(:md, Node(:codecell,
            Node(:codeinput, Node(:codeblock, "print(\"hi\")")),
            Node(:codeoutput, Node(:codeblock, "hi"))
        ))
    end
    @testset "Cache" begin
        # If a code block doesn't change, the result should be cached
        rewriter = ExecuteCode(codeblocksel = SelectTag(:codeblock))
        doc = Node(:md, Node(:codeblock, "rand()"))
        outdoc = Pollen.rewritedoc(rewriter, "path", doc)
        val = only(children(selectfirst(outdoc, SelectTag(:coderesult))))[]
        outdoc2 = Pollen.rewritedoc(rewriter, "path", doc)
        val2 = only(children(selectfirst(outdoc2, SelectTag(:coderesult))))[]
        @test val == val2

        # After a reset, the caches should be cleared
        reset!(rewriter)
        outdoc3 = Pollen.rewritedoc(rewriter, "path", doc)
        val3 = only(children(selectfirst(outdoc3, SelectTag(:coderesult))))[]
        @test val != val3
    end
end
