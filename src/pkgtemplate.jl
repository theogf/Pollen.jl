
const POLLEN_TEMPLATE_DIR =
    Ref{String}(joinpath(dirname(dirname(pathof(Pollen))), "templates"))


"""
    PollenPlugin() <: Plugin

Sets up Pollen.jl documentation for a package.

## Extended

Performs the following steps:

- creates a `docs/` folder with default files `project.jl`, `serve.jl`, `make.jl`
    and `toc.json`
- creates the GitHub actions for building the documentation data and the frontend
- creates an empty (orphan) branch "pollen" where documentation data will be built to
    by GitHub Actions
"""
@plugin struct PollenPlugin <: Plugin
    folder::String = "docs"
    branch_data::String = "pollen"
    branch_page::String = "gh-pages"
    branch_primary::String = "main"
    remote::Union{String, Nothing} = "origin"
    pollen_spec::Pkg.PackageSpec =
        Pkg.PackageSpec(url = "https://github.com/lorenzoh/Pollen.jl", rev = "main")
    moduleinfo_spec::Pkg.PackageSpec =
        Pkg.PackageSpec(url = "https://github.com/lorenzoh/ModuleInfo.jl", rev = "main")
end



# Setup and validation steps


function setup_docs(
    dir::String,
    plugin = Pollen.PollenPlugin();
    verbose = true,
    force = false,
)
    # ## Checks
    # check isdir
    isdir(dir) || throw(SystemError("Directory `$dir` not found!"))
    # check isfile Project.toml
    projfile = joinpath(dir, "Project.toml")
    if !isfile(projfile)
        throw(
            SystemError(
                "Project file `$dir/Project.toml` not found! Please pass a valid Julia package directory.",
            ),
        )
    end

    verbose && @info "Rendering templates in docs subfolder `$(plugin.folder)"
    setup_docs_files(dir, plugin; verbose, force)
    verbose && @info "Rendering GitHub Actions templates in `.github/worflows`"
    setup_docs_actions(dir, plugin; verbose, force)
    verbose &&
        @info "Setting up Julia project with docs dependencies in subfolder `$(plugin.folder)`"
    setup_docs_project(dir, plugin; verbose, force)

    if verbose
        @info "If you want to host a site on GitHub Pages and haven't done so, check and
        commit the changes made by `setup_docs` and then run `setup_docs_branches`."
    end
end


TEMPLATES_DOCS = ["project.jl", "make.jl", "serve.jl", "toc.json"]
TEMPLATES_ACTIONS = [
    "pollen.build.yml",
    "pollen.trigger.dev.yml",
    "pollen.trigger.pr.yml",
    "pollen.trigger.release.yml",
    "pollen.render.yml",
]

function setup_docs_files(
    dir::String,
    plugin = PollenPlugin();
    verbose = true,
    force = false,
)
    # Validation
    isdir(dir) || throw(SystemError("Directory `$dir` not found!"))
    docsdir = joinpath(dir, plugin.folder)
    isdir(docsdir) || mkdir(docsdir)
    docsfiles = [joinpath(docsdir, f) for f in TEMPLATES_DOCS]
    for file in docsfiles
        if !force && isfile(file)
            throw(
                SystemError(
                    "File `$file` already exists. Pass `force = true` to overwrite any previous configuration.",
                    2,
                ),
            )
        end
    end

    # Running

    config = _docs_config(dir, plugin)
    for template in TEMPLATES_DOCS
        _rendertemplate(template, docsdir, config)
    end
end

function setup_docs_actions(
    dir::String,
    plugin = PollenPlugin();
    verbose = true,
    force = false,
)
    # Validation
    isdir(dir) || throw(SystemError("Directory `$dir` not found!"))
    actionsdir = joinpath(dir, ".github/workflows")
    isdir(actionsdir) || mkpath(docsdir)
    actionfiles = [joinpath(actionsdir, f) for f in TEMPLATES_ACTIONS]
    for file in actionfiles
        if !force && isfile(file)
            throw(
                SystemError(
                    "File `$file` already exists. Pass `force = true` to overwrite any previous configuration.",
                    2,
                ),
            )
        end
    end

    # Write the files
    config = _docs_config(dir, plugin)
    for template in TEMPLATES_ACTIONS
        _rendertemplate(template, actionsdir, config)
    end
end


function setup_docs_branches(dir::String, plugin = PollenPlugin(); force = false)
    if !_iscleanworkingdir(dir)
        throw(SystemError("""The working directory of git repository $dir is not clean. Please
                             commit or stash all changes before running `setup_docs_branches`.
                             This will create two branches and push them to the remote, but can
                             only do so with a clean working directory."""))
    end
    # Create orphaned branch `pollen` that stores the documentation data (default "pollen")
    # TODO: Maybe add render workflow to this branch
    if !_hasbranch(dir, plugin.branch_data) || force
        _createorphanbranch(dir, plugin.branch_data, remote = plugin.remote)
        # TODO: add .nojekyll file
    end

    # Create orhpaned branch that the website will be built to (default "gh-pages")
    if !_hasbranch(dir, plugin.branch_page) || force
        _createorphanbranch(dir, plugin.branch_page, remote = plugin.remote)
    end
end


function setup_docs_project(dir, plugin = PollenPlugin(); force = false, verbose = false)
    isdir(dir) || throw(SystemError("Directory `$dir` not found!"))
    docsdir = joinpath(dir, plugin.folder)
    if isdir(docsdir) && isfile(joinpath(docsdir, "Project.toml"))
        force || throw(
            SystemError(
                "There is already a Julia project at `$docsdir`. Pass `force = true` to overwrite.",
            ),
        )
    end
    isdir(docsdir) || mkdir(docsdir)
    # TODO: check if it
    cd(dir) do
        PkgTemplates.with_project(docsdir) do
            Pkg.add([plugin.pollen_spec, plugin.moduleinfo_spec])
            Pkg.develop(Pkg.PackageSpec(path = dir))
        end
    end
end

function _rendertemplate(name, dst, config)
    PkgTemplates.gen_file(
        joinpath(dst, name),
        PkgTemplates.render_file(
            joinpath(POLLEN_TEMPLATE_DIR[], name),
            config,
            ("<<", ">>"),
        ),
    )
end

function _docs_config(dir::String, plugin::PollenPlugin)
    return Dict{String,Any}(
        "PKG" => split(dir, "/")[end],
        "DOCS_FOLDER" => plugin.folder,
        "BRANCH_DATA" => plugin.branch_data,
        "BRANCH_PAGE" => plugin.branch_page,
    )
end



# Hooks for PkgTemplates

PkgTemplates.priority(::PollenPlugin) = -1000

function PkgTemplates.validate(::PollenPlugin, t::Template) end

function PkgTemplates.prehook(p::PollenPlugin, ::Template, pkg_dir::AbstractString)
    setup_docs_branches(pkg_dir, p)
end


function PkgTemplates.hook(plugin::PollenPlugin, t::Template, pkg_dir::AbstractString)
    setup_docs_files(pkg_dir, plugin)
    setup_docs_actions(pkg_dir, plugin)
    _withbranch(pkg_dir, plugin.branch_primary) do
        Git.git(["add", "."]) |> readchomp |> println
        Git.git(["commit", "-m", "'Setup Pollen.jl template files'"]) |>
        readchomp |>
        println
    end
end

function PkgTemplates.posthook(plugin::PollenPlugin, t::Template, pkg_dir::AbstractString)
    # Setup the environment for building the docs
    setup_docs_project(pkg_dir, plugin)

    #=
    _withbranch(pkg_dir, p.branch_data) do
        rendertemplate("pollenbuild.yml", folder_actions)
        rendertemplate("pollenstatic.yml", folder_actions)
        Git.git(["add", "."]) |> readchomp |> println
        Git.git(["commit", "-m", "Add actions to data branch"]) |> readchomp |> println
    end
    _withbranch(pkg_dir, p.branch_page) do
        touch(".nojekyll")
        Git.git(["add", "."]) |> readchomp |> println
        Git.git(["commit", "-m", "Add .nojekyll"]) |> readchomp |> println
    end
    sleep(0.1)
    =#
end


function PkgTemplates.view(p::PollenPlugin, ::Template, pkg_dir::AbstractString)
    return Dict{String,Any}(
        "PKG" => split(pkg_dir, "/")[end],
        "DOCS_FOLDER" => p.folder,
        "BRANCH_DATA" => p.branch_data,
        "BRANCH_PAGE" => p.branch_page,
    )
end

# Git utilities

function _withbranch(f, dir, branch; options = String[], verbose = true)
    _println(args...) = verbose ? println(args...) : nothing

    isdir(dir) || throw(ArgumentError("\"$dir\" is not an existing directory!"))
    isdir(joinpath(dir, ".git")) ||
        throw(ArgumentError("\"$dir\" is not a git repository!"))

    cd(dir) do
        prevbranch = readchomp(Git.git(["branch", "--show-current"]))
        try
            Git.git(["checkout", options..., branch]) |> readchomp |> _println
            f()
        catch e
            rethrow()
        finally
            Git.git(["checkout", prevbranch]) |> readchomp |> _println
        end
    end
end

function _hasbranch(dir, branch)
    try
        cd(
            () ->
                pipeline(Git.git(["rev-parse", "--quiet", "--verify", branch])) |>
                readchomp,
            dir,
        )
        return true
    catch
        return false
    end
end

function _iscleanworkingdir(dir)
    cd(dir) do
        isempty(strip(readchomp(Pollen.Git.git(["status", "-s"]))))
    end
end

function _createorphanbranch(repo::String, branch::String; remote = nothing)
    return _withbranch(repo, branch, options = ["--orphan"]) do
        readchomp(Git.git(["reset", "--hard"])) |> println
        readchomp(
            Git.git(["commit", "--allow-empty", "-m", "Empty branch for Pollen.jl data"]),
        ) |> println
        if !isnothing(remote)
            readchomp(Git.git(["push", "--set-upstream", remote, branch])) |> println

        end
    end
end


# Tests

@testset "Documentation setup" begin
    @testset "Package template" begin
        template = PkgTemplates.Template([

        ])
        mktempdir() do dir
            @test_nowarn template(joinpath(dir, "TempPackage"))
        end
    end
end
