module GenieTest

using Test
export App, wait_for, notify_test, @App, connect!, redirect!, goto, is_reactive

using Reexport
@reexport using Stipple
@reexport using Stipple.ReactiveTools
import HTTP
using Electron
using UUIDs

export toggle_devtools

abstract type DummyWindow end
Base.run(w::Union{DummyWindow, Window}, code::JSONText) = run(w, json(code))

"""
    unproxy(msg::String)

Workaround for a JS Error in Electron when parsing proxy objects.
"""
function unproxy(msg::String)
    "(x => (window.Vue) && Vue.isProxy(x) ? JSON.parse(JSON.stringify(x)) : x)($msg)"
end

"""
    jsclone(msg::String)

Workaround for a JS Error in Electron when parsing proxy objects.
"""
function jsclone(msg::String)
    "JSON.parse(JSON.stringify($msg))"
end

function Base.getindex(win::Window, index::Union{AbstractString, JSONText})
    index isa JSONText && (index = json(index))
    startswith(index, '[') || (index = ".$index")
    run(win, unproxy("GENIEMODEL$index"))
end

function Base.setindex!(win::Window, val, index::Union{AbstractString, JSONText})
    index isa JSONText && (index = json(index))
    startswith(index, '[') || (index = ".$index")
    js_value = json(render(val))
    code = if endswith(index, r"juliaGet\(\d+\)")
        index = replace(index, r"juliaGet\((\d+)\)$" => s"juliaSet(\1")
        "window?.GENIEMODEL$index, $js_value)"
    else
        """window?.GENIEMODEL.setField("$index", $js_value)"""
    end
    run(win, unproxy(code))
end

function Base.notify(win::Window, field::Symbol, priorities = nothing)
    priorities === Stipple.ReactiveTools.NO_NOTIFY && return false
    
    # no listener priorities available on the client side, so only evaluate priorities for level 0
    priorities isa Function && priorities(0) === false && return false
    
    run(win, js"""window?.GENIEMODEL?.push('$field')"""i)
end

function Base.notify(win::Window, message::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...)
    d = Stipple.opts(;type, message, kwargs...)
    js_dict = strip(json(d), '"')
    run(win, js"""window?.GENIEMODEL?.\$q.notify($js_dict); null"""i)
end

Base.@kwdef mutable struct App
    __model__::Union{ReactiveModel, Nothing} = nothing
    __window__::Union{Window, Nothing} = nothing
    __priority__::Symbol = :model
    __id__::String = ""
    __url__::String = ""
    __electron_options__::Dict{String, Any} = Dict{String, Any}()
    __timeout__::Float64 = 30.0
    __port__::Union{Int, Nothing} = nothing
end

function remove_id(url::Union{String, URI})::URI
    uri = URI(url)
    query = replace(uri.query, r"debug_id=[^&/]+&?" => "")
    if isempty(query)
        # explicitly adding an empty query adds a '?' at the end
        url = URI(chopsuffix(string(URI(uri; query = "")), '?'))
    else
        URI(uri; query)
    end
end

const AppDict = Dict{Any, App}

function Base.getproperty(app::App, fieldname::Symbol)
    fieldname ∈ fieldnames(App) && return getfield(app, fieldname)

    if app.__priority__ == :window && app.__window__ !== nothing
        run(app.__window__, unproxy("window?.GENIEMODEL?.$fieldname"))
    elseif app.__model__ !== nothing
        model = getfield(app, :__model__)
        if !hasproperty(model, fieldname)
            field_str = String(fieldname)
            new_fieldname = Symbol(field_str[1:end-1])
            if endswith(field_str, "!") && hasproperty(model, new_fieldname)
                getfield(model, new_fieldname)
            else
                error("Field $(fieldname) does not exist in model $(model).")
            end
        else
            field = getfield(model, fieldname)
            field isa Reactive ? field[] : field
        end
    elseif app.__window__ !== nothing && app.__window__.exists
        run(app.__window__, unproxy("window?.GENIEMODEL?.$fieldname"))
    else
        @warn("App has neither model nor active window")
    end
end

function Base.setproperty!(app::App, fieldname::Symbol, value)
    fieldname ∈ fieldnames(App) && return setfield!(app, fieldname, value)

    if app.__priority__ == :window && app.__window__ !== nothing
        js_value = json(render(value))
        run(app.__window__, unproxy("GENIEMODEL.$fieldname = $js_value"))
    elseif app.__model__ !== nothing
        field = getfield(app.__model__, fieldname)
        if field isa Reactive
            field[] = value
        else
            setfield!(app.__model__, fieldname, value)
        end
    elseif app.__window__ !== nothing
        app.__window__[String(fieldname)] = value
    else
        @warn("App has neither model nor window")
    end
end

function Base.getindex(app::App, fieldname::Symbol)
    getproperty(app, fieldname::Symbol)
end

function Base.setindex!(app::App, value, fieldname::Symbol)
    if app.__model__ === nothing
        @warn "App has no backend model to set field without notification"
        return
    end
    field = getfield(app.__model__, fieldname)
    if field isa Reactive
        getfield(field, :o).val = value
    else
        setfield!(app.__model__, fieldname, value)
    end
end

function Base.setindex!(app::App, value, fieldname::Symbol, priorities)
    if app.__model__ === nothing
        @warn "App has no backend model to set field with priorities"
        return
    end
    field = getfield(app.__model__, fieldname)
    if field isa Reactive
        setindex!(app.__model__, value, fieldname, priorities)
    else
        setfield!(app.__model__, fieldname, value)
    end
end

function Base.getindex(app::App, index::Union{AbstractString, JSONText})
    getindex(app.__window__, index)
end

function Base.setindex!(app::App, val, index::Union{AbstractString, JSONText})
    setindex!(app.__window__, val, index)
end

# Will be moved to Stipple, therefore adding it here as a Union to prevent overwrite error.
Base.getindex(model::Union{Nothing, ReactiveModel}, field::Symbol) = model === nothing ? nothing : getfield(model, field)

function Base.notify(app::App, field::Symbol, priorities = nothing)
    # level is only introduced to support common calling via @notify macro
    if app.__model__ !== nothing
        notify(getfield(app.__model__, field), priorities)
    elseif app.__window__ !== nothing
        notify(app.__window__, field, priorities)
    else
        false
    end
end

function Base.notify(app::App, message::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...)
    if app.__model__ !== nothing
        notify(app.__model__, message, type; kwargs...)
    else
        notify(app.__window__, message, type; kwargs...)
    end
end

function add_id(url::Union{String, URI}, id::String)
    uri = URI(url)
    isempty(id) ? URI(uri) : URI(uri, query = join(filter(!isempty, ["debug_id=$id", uri.query]), '&'))
end

"""
    App(url::String = "/";
    timeout::Float64 = 30,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = startswith(url, r"https://"i) || !backend ? :electron : :browser,
    backend::Bool = !startswith(url, r"https://"i),
    isready::Function = app -> app.isready
)

Create a Stipple App with optional frontend and backend.
# Arguments
- `url::String = "/"`: URL to open in the frontend. If it does not start with
  "http://" or "https://", it is assumed to be "http://localhost:port/".
# Keyword Arguments
- `timeout::Float64 = 30`: Timeout in seconds to wait for the backend to be ready.
- `port = nothing`: Port where the Genie server is running. If `nothing`,
  it uses `Genie.config.server_port`.
- `id::String = string(uuid4())`: Debug ID used to identify the Stipple model
  in the backend.
- `frontend::Symbol = :browser`: Frontend to use. Can be `:browser`, `:electron`,
  or `:none`. If `:browser`, it opens the URL in the default browser. If `:electron`, it
  opens an Electron window. If `:none`, it does not open any frontend.
- `backend::Bool = true`: Whether to start the backend Stipple model. If `false`,
  only the frontend is started. This can be useful for testing remote apps.
- `backend_ready::Function = app -> app.isready === true`: Function to check if the
  backend is ready. It takes the Stipple model as argument and should return
  `true` if the backend is ready. By default, it checks the `isready` field
  of the model.
# Returns
An `App` instance containing the backend model and the frontend window.
"""
function App(url::Union{String, URI};
    timeout::Real = 30,
    port = nothing,
    id::String = string(uuid4()),
    backend::Bool = !startswith(string(url), r"https://"i),
    frontend::Symbol = startswith(string(url), r"https://"i) || !backend ? :electron : :browser,
    isready::Function = app -> app.isready === true,
    electron_options::Dict{String, <:Any} = Dict{String, Any}(),
    priority::Symbol = :model,
    window::Union{Window, Nothing} = nothing
)
    port === nothing && (port = Genie.config.server_port)
    println()
    @info "--------------   Starting App --------------"
    uri = URI(url)
    isempty(uri.scheme) && (uri = URI(uri; scheme = "http", host = "localhost", port, path = string('/', strip(uri.path, '/'))))
    final_uri = add_id(uri, id)

    win = if window !== nothing && window.exists
        Electron.load(window, final_uri)
        window
    elseif frontend == :electron
        # default to sandbox mode
        electron_options = Dict{String, Any}(electron_options)
        wp = get!(electron_options, "webPreferences", Dict{String, Any}())
        electron_options["webPreferences"] = merge(Dict{String, Any}("sandbox" => true), wp)

        Window(final_uri, options = electron_options)
    elseif frontend == :browser
        Genie.Server.openbrowser(final_uri)
        nothing
    else
        HTTP.get(final_uri)
        nothing
    end

    model = nothing
    
    if backend
        model = Stipple.debug_model(id; timeout)
        frontend == :none && (model.isready[] = true)
    end
    
    app = App(model, win, priority, id, "$uri", electron_options, float(timeout), port)
    if model === nothing && win === nothing
        @warn("App has neither frontend nor backend")
        return app
    end
    print("Waiting for App to be ready ")
    t0 = time()
    dt = time() - t0
    while !isready(app) && dt < timeout
        delay = dt < 1 ? 0.1 : 1
        sleep(delay)
        delay > 1 && print('.')
        dt = time() - t0
    end
    println()

    if !isready(app) === true
        # close(app)
        @warn("App could not be created correctly")
    else
        @info "App ready"
    end
    
    return app
end

function App(::Type{T}; kwargs...) where T <: ReactiveModel
    model = Stipple.ReactiveTools.init_model(T; kwargs...)
    model.isready[] = true
    return App(__model__ = model; kwargs...)
end

App(context::Module) = App(@eval context Stipple.@type)

"""
    App(app::App, args...;
        timeout::Real = app.__timeout__,
        port = app.__port__,
        id::String = app.__id__,
        backend::Bool = app.__model__ !== nothing,
        frontend::Symbol = app.__window__ !== nothing ? :electron : :none,
        isready::Function = app -> app.isready === true,
        electron_options::Dict{String, <:Any} = app.__electron_options__,
        priority::Symbol = app.__priority__,
        window::Union{Window, Nothing} = app.__window__
    )

Reinitialize an existing app with new settings or URL.

This method allows you to update an existing `App` instance by creating a new app
with different parameters and then transferring all fields to the original instance.
All keyword arguments default to the current app's settings.

# Arguments
- `app::App`: The existing app instance to reinitialize.
- `args...`: Additional positional arguments (typically a new URL) passed to the main `App` constructor.

# Keyword Arguments
- `timeout::Real`: Timeout in seconds for app initialization.
- `port`: Port where the Genie server is running.
- `id::String`: Debug ID for the app.
- `backend::Bool`: Whether the backend model should be active.
- `frontend::Symbol`: Frontend type (`:electron`, `:browser`, or `:none`).
- `isready::Function`: Function to check if the backend is ready.
- `electron_options::Dict{String, <:Any}`: Options for the Electron window.
- `priority::Symbol`: Priority for getting/setting properties (`:model` or `:window`).
- `window::Union{Window, Nothing}`: Existing window to reuse.

# Returns
The modified `App` instance.
"""
function App(app::App, args...;
    timeout::Real = app.__timeout__,
    port = app.__port__,
    id::String = app.__id__,
    backend::Bool = app.__model__ !== nothing,
    frontend::Symbol = app.__window__ !== nothing ? :electron : :none, # use the existing window
    isready::Function = app -> app.isready === true,
    electron_options::Dict{String, <:Any} = app.__electron_options__,
    priority::Symbol = app.__priority__,
    window::Union{Window, Nothing} = app.__window__
)
    a = App(args...; timeout, port, id, backend, frontend, isready, electron_options, priority, window)
    for field in fieldnames(App)
        setfield!(app, field, getfield(a, field))
    end
end

macro App()
    :(App(@__MODULE__))
end

function Base.propertynames(app::App)
    if app.__model__ !== nothing
        tuple(propertynames(app.__model__)..., fieldnames(App)...)
    elseif app.__window__ !== nothing && app.__window__.exists
        fnames = run(app.__window__, """
            (x => Object.keys(x).filter(k => typeof x[k] !== 'function' && k !== 'WebChannel'))(window?.GENIEMODEL || {})
            """)
        tuple(Symbol.(fnames)..., fieldnames(App)...)
    else
        fieldnames(App)
    end
end

function Base.run(app::App, msg::Union{AbstractString, JSONText}; timeout = 1, clone_result::Union{Bool, Nothing} = true)
    if app.__window__ !== nothing
        if ! app.__window__.exists
            @warn "Cannot run code on window, it probably has been closed."
            return nothing
        end
        msg isa JSONText && (msg = json(msg))
        if clone_result === nothing # automatically clone if necessary
            try
                run(app.__window__, unproxy(msg))
            catch
                run(app.__window__, jsclone(msg))
            end
        elseif clone_result === true
            run(app.__window__, jsclone(msg))
        else
            run(app.__window__, msg)
        end
    elseif app.__model__ !== nothing
        read(app.__model__, msg; timeout)
    end
end

function Base.close(app::App)
    app.__model__ !== nothing && run(app.__model__, "window.close()")
    app.__window__ !== nothing && close(app.__window__.app)
end

function print_object(io, app::App, compact = false)
    println(io, "Instance of 'GenieTest.App'")
    compact && return
    
    print(io, "    backend:  ", app.__model__ === nothing ? "nothing" : "")
    app.__model__ === nothing ? println() : print(app.__model__)
    println(io, "    frontend: ", app.__window__ === nothing ? "nothing" : "Electron.Window")
end

# default show used by Array show
function Base.show(io::IO, app::App)
    compact = get(io, :compact, true)
    print_object(io, app, compact)
end

# default show used by display() on the REPL
function Base.show(io::IO, mime::MIME"text/plain", app::App)
    compact = get(io, :compact, false)
    print_object(io, app, compact)
end

# Utility function to wait for a condition with timeout
function wait_for(f; success = true, fail = false, timeout::Real = 10, delay::Real = 1)
    t0 = time()
    while time() < t0 + timeout
        f() && return success
        sleep(delay)
    end
    f() ? success : fail
end

function notify_test(model::ReactiveModel, test::Test.Result, test_str::AbstractString = "Test")
    success = test isa Test.Pass
    notify(model, "$test_str $(success ? "succeeded!" : "failed!")", type = success ? "positive" : "negative")
end

function notify_test(win::Window, test::Test.Result, test_str::AbstractString = "Test")
    success = test isa Test.Pass
    notify(win, "$test_str $(success ? "succeeded!" : "failed!")", type = success ? "positive" : "negative")
end

function notify_test(app::App, test::Test.Result, test_str::AbstractString = "Test")
    if app.__model__ !== nothing
        notify_test(app.__model__, test, test_str)
    elseif app.__window__ !== nothing
        notify_test(app.__window__, test, test_str)
    end
end

function merge_uri(base_uri::URI, new_uri::URI)
    !isempty(new_uri.scheme) && return new_uri

    base_kwargs = filter(!isempty ∘ last, Dict(k => getfield(base_uri, k) for k in fieldnames(URI) if k ∉ [:uri, :query, :fragment]))
    new_kwargs = filter(!isempty ∘ last, Dict(k => getfield(new_uri, k) for k in fieldnames(URI) if k !== :uri))
    new_path = if startswith(new_uri.path, '/') ||  base_uri.path == ""
        string('/', chopprefix(new_uri.path, "/"))
    else
        base_url = string('/', chopprefix(base_uri.path, "/"))
        relative_url = chopprefix(new_uri.path, "/")
        join(filter(!isempty, [base_url, relative_url]), '/')
    end
    new_kwargs[:path] = new_path
    merge!(base_kwargs, new_kwargs)
    URI(; base_kwargs...)
end

"""
    redirect!(app::App, url::Union{String, URI}; id = app.__id__)

Redirect the app to a new URL while preserving the app state and optionally changing the debug ID.

This function updates the app's internal URL state and performs a redirect in the frontend.
If the URL is relative, it will be merged with the current base URL. The function will
attempt to update the window location, or recreate the app connection if necessary.

# Arguments
- `app::App`: The app instance to redirect.
- `url::Union{String, URI}`: The new URL to navigate to. Can be relative or absolute.

# Keyword Arguments
- `id = app.__id__`: Debug ID for the new page. Defaults to the current app ID.

# Returns
The modified `App` instance.
"""
function redirect!(app::App, url::Union{String, URI}; id = app.__id__)
    uri = merge_uri(URI(app.__url__), URI(url))
    if isempty(uri.scheme)
        uri = URI(app.__url__; path = join(uri.path))
    end
    app.__url__ = "$uri"
    app.__id__ = id
    final_uri = add_id(uri, id)
    if run(app, "window.location = '$final_uri'") === nothing
        App(app, final_uri)
    end
    return app
end

"""
    goto(app::App, url::Union{String, URI}; id = app.__id__)

Navigate the app to a new URL by directly setting the window location.

Unlike `redirect!`, this function does not update the app's internal state and performs
a simple navigation by setting the window location. The URL is not merged with the base URL.

# Arguments
- `app::App`: The app instance to navigate.
- `url::Union{String, URI}`: The URL to navigate to.

# Keyword Arguments
- `id = app.__id__`: Debug ID to append to the URL. Defaults to the current app ID.

# Returns
The result of the JavaScript execution (typically `nothing`).
"""
function goto(app::App, url::Union{String, URI}; id = app.__id__)
    uri = add_id(url, id)
    run(app, "window.location = '$uri'")
end

"""
    is_reactive(app::App)

Check if the app's reactive model is ready and available.

This function queries the frontend to determine if the Genie reactive model is loaded
and ready for interaction. It checks the `window.GENIEMODEL.isready` property.

# Arguments
- `app::App`: The app instance to check.

# Returns
`true` if the reactive model is ready, `false` otherwise (including if an error occurs).
"""
function is_reactive(app::App)
    try
        run(app, "window?.GENIEMODEL?.isready || false")
    catch
        false
    end
end

"""
    connect!(app::App; timeout = nothing, port = nothing, isready::Function = app -> app.isready === true)

Ensure the app is connected and recreate the window if it has been closed.

This function checks if the app's window exists and attempts to recreate it if it has been
closed. If the window is already available, it returns `true` immediately.

# Arguments
- `app::App`: The app instance to connect or reconnect.

# Keyword Arguments
- `timeout = nothing`: Timeout in seconds for waiting for the app to be ready.
  If `nothing`, uses the app's current timeout setting.
- `port = nothing`: Port where the Genie server is running. If `nothing`, uses
  the app's current port setting.
- `isready::Function = app -> app.isready === true`: Function to check if the
  backend is ready.

# Returns
`true` if the connection is successful or if the window already exists, `false` if
recreation fails.
"""
function connect!(app::App; timeout = nothing, port = nothing, isready::Function = app -> app.isready === true)
    if app.__window__ !== nothing
        if !app.__window__.exists
            @info "App window appears to be closed. Recreating the window..."
            try
                a = App(
                    app.__url__,
                    id = app.__id__,
                    frontend = :electron,
                    electron_options = app.__electron_options__,
                    priority = app.__priority__,
                    backend = app.__model__ !== nothing,
                    timeout = timeout === nothing ? app.__timeout__ : timeout,
                    port = port === nothing ? app.__port__ : port,
                )
                app.__model__ = a.__model__
                app.__window__ = a.__window__
                app.__port__ = a.__port__
                app.__timeout__ = a.__timeout__
                true
            catch e
                @warn "Failed to recreate app window: $e"
                false
            end
        else
            # the window is available, but the content has been
            true
        end
    else
        true
    end
end

Electron.toggle_devtools(app::App) = app.__window__ !== nothing && toggle_devtools(app.__window__)

end # GenieTest