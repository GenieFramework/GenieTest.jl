module GenieTest

using Test
export App, wait_for, notify_test, assert_connection!, redirect!, reload, goto, is_reactive
export click, get_html, trigger_event

using Reexport
@reexport using Stipple
@reexport using Stipple.ReactiveTools
import HTTP
using HTTP: URI
using Base64
using JSON
using UUIDs

export toggle_devtools
export Client, is_connected

include("Frontend.jl")
include("Client.jl")

frontend_kind(::Client) = :client
has_js(::Client) = false
is_usable(::Client) = true

function create_frontend(::Val{:client}, uri; timeout = 30, kwargs...)
    # like a Window, a client that cannot connect yet does not abort the setup;
    # assert_connection!(app) can be used to establish the connection later
    client = Client(uri)
    connect!(client; timeout)
    client
end

mutable struct App
    __model__::Union{ReactiveModel, Nothing}
    __frontend__::Union{Nothing, AbstractFrontend}
    __priority__::Symbol
    __id__::String
    __url__::String
    __electron_options__::Dict{String, Any}
    __timeout__::Float64
    __port__::Union{Int, Nothing}
    __frontend_options__::Dict{Symbol, Any}
end

"""
    normalize_priority(priority::Symbol)

Validate the access priority of an `App`: `:backend` (model first) or `:frontend`
(window or client first). `:window` is a deprecated alias for `:frontend`.
"""
function normalize_priority(priority::Symbol)
    if priority === :window
        Base.depwarn("priority = :window is deprecated, use :frontend instead.", :normalize_priority)
        return :frontend
    end
    priority ∈ (:backend, :frontend) || throw(ArgumentError("priority must be :backend or :frontend, got :$priority"))
    priority
end

function App(;
    __model__::Union{ReactiveModel, Nothing} = nothing,
    __frontend__ = nothing,
    __window__ = nothing,
    __priority__::Symbol = :backend,
    __id__::String = "",
    __url__::String = "",
    __electron_options__::Dict{String, Any} = Dict{String, Any}(),
    __timeout__::Float64 = 30.0,
    __port__::Union{Int, Nothing} = nothing,
    __frontend_options__::AbstractDict{Symbol} = Dict{Symbol, Any}()
)
    frontend = as_frontend(__frontend__ === nothing ? __window__ : __frontend__)
    App(__model__, frontend, normalize_priority(__priority__), __id__, __url__, __electron_options__, __timeout__, __port__, Dict{Symbol, Any}(__frontend_options__))
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

"""
    access_target(app::App)

Return where model fields of `app` are read and written: `:model` (backend), `:frontend`
or `:none`. If both a backend model and a usable frontend (a `Client` or an existing
usable frontend) are available, `app.__priority__` decides, otherwise the available one is used.
"""
function access_target(app::App)
    model = getfield(app, :__model__)
    frontend = getfield(app, :__frontend__)
    frontend_usable = frontend !== nothing && is_usable(frontend)
    if model === nothing
        frontend_usable ? :frontend : :none
    elseif frontend_usable && getfield(app, :__priority__) === :frontend
        :frontend
    else
        :model
    end
end

function Base.getproperty(app::App, fieldname::Symbol)
    if fieldname === :__window__
        frontend = getfield(app, :__frontend__)
        return frontend_window(frontend)
    end
    fieldname ∈ fieldnames(App) && return getfield(app, fieldname)

    frontend = getfield(app, :__frontend__)
    target = access_target(app)
    if target === :frontend
        if frontend isa Client
            getproperty(frontend, fieldname)
        else
            get_model_field(frontend, fieldname)
        end
    elseif target === :model
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
    else
        @warn("App has neither model nor active frontend")
    end
end

function Base.setproperty!(app::App, fieldname::Symbol, value)
    if fieldname === :__window__
        # clearing the window must not drop a different frontend
        (value !== nothing || frontend_window(getfield(app, :__frontend__)) !== nothing) && setfield!(app, :__frontend__, as_frontend(value))
        return value
    elseif fieldname === :__priority__
        return setfield!(app, fieldname, normalize_priority(value))
    elseif fieldname ∈ fieldnames(App)
        return setfield!(app, fieldname, value)
    end

    frontend = getfield(app, :__frontend__)
    target = access_target(app)
    if target === :frontend
        if frontend isa Client
            setproperty!(frontend, fieldname, value)
        elseif getfield(app, :__model__) === nothing
            frontend[String(fieldname)] = value
        else
            set_model_field!(frontend, fieldname, value)
        end
    elseif target === :model
        model = getfield(app, :__model__)
        field = getfield(model, fieldname)
        if field isa Reactive
            field[] = value
        else
            setfield!(model, fieldname, value)
        end
    else
        @warn("App has neither model nor frontend")
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
    frontend = app.__frontend__
    frontend === nothing && error("JavaScript property access requires a frontend with JavaScript support.")
    getindex(frontend, index)
end

function Base.setindex!(app::App, val, index::Union{AbstractString, JSONText})
    frontend = app.__frontend__
    frontend === nothing && error("JavaScript property access requires a frontend with JavaScript support.")
    setindex!(frontend, val, index)
end

# Will be moved to Stipple, therefore adding it here as a Union to prevent overwrite error.
Base.getindex(model::Union{Nothing, ReactiveModel}, field::Symbol) = model === nothing ? nothing : getfield(model, field)

function Base.notify(app::App, field::Symbol, priorities = nothing)
    # level is only introduced to support common calling via @notify macro
    if app.__model__ !== nothing
        notify(getfield(app.__model__, field), priorities)
    elseif app.__frontend__ !== nothing
        notify(app.__frontend__, field, priorities)
    else
        false
    end
end

function Base.notify(app::App, message::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...)
    if app.__model__ !== nothing
        notify(app.__model__, message, type; kwargs...)
    elseif app.__frontend__ !== nothing && has_js(app.__frontend__)
        notify(app.__frontend__, message, type; kwargs...)
    else
        false
    end
end

function Base.notify(client::Client, field::Symbol, priorities = nothing)
    priorities === Stipple.ReactiveTools.NO_NOTIFY && return false
    priorities isa Function && priorities(0) === false && return false
    send_watch(client, field, getfield_(client, String(field)))
end

Base.notify(::Client, ::AbstractString, ::Union{Nothing, String, Symbol} = nothing; kwargs...) = false

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
    isready::Function = app -> app.isready,
    priority::Symbol = :backend
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
  `:client`, `:playwright` (needs `using Playwright`) or `:none`. If `:browser`, it opens the URL in the default browser. If
  `:electron`, it opens an Electron window. If `:client`, it connects a headless
  WebChannel client. If `:none`, it does not open any frontend.
- `priority::Symbol = :backend`: Where `app.field` is read and written if both a backend
  model and a frontend (e.g. an Electron window or a `Client`) are available: `:backend` (model first) or
  `:frontend`. This allows e.g. to attach a backend for inspection while reading the values
  as the frontend sees them. If only one side is available, it is used regardless of the
  priority. Indexing with a string (`app["..."]`) always addresses the frontend,
  `app[:field] = value` always the backend model (without notification).
- `frontend_options::AbstractDict{Symbol} = Dict{Symbol, Any}()`: Options for the frontend, see the
  documentation of the frontend (e.g. `:profile`, `:headless`, `:engine` for `:playwright`).
- `backend::Bool = true`: Whether to start the backend Stipple model. If `false`,
  only the frontend is started. This can be useful for testing remote apps.
- `backend_ready::Function = app -> app.isready === true`: Function to check if the
  backend is ready. It takes the Stipple model as argument and should return
  `true` if the backend is ready. By default, it checks the `isready` field
  of the model.
# Returns
An `App` instance containing the backend model and the selected frontend.
"""
function App(url::Union{String, URI};
    timeout::Real = 30,
    port = nothing,
    id::String = string(uuid4()),
    backend::Bool = !startswith(string(url), r"https://"i),
    frontend::Symbol = startswith(string(url), r"https://"i) || !backend ? :electron : :browser,
    isready::Function = app -> app.isready === true,
    electron_options::Dict{String, <:Any} = Dict{String, Any}(),
    priority::Symbol = :backend,
    window = nothing,
    frontend_options::AbstractDict{Symbol} = Dict{Symbol, Any}()
)
    port === nothing && (port = Genie.config.server_port)
    println()
    @info "--------------   Starting App --------------"
    uri = URI(url)
    isempty(uri.scheme) && (uri = URI(uri; scheme = "http", host = "localhost", port, path = string('/', strip(uri.path, '/'))))
    final_uri = add_id(uri, id)

    window_frontend = as_frontend(window)
    frontend_instance = if window_frontend !== nothing && is_usable(window_frontend)
        create_frontend(Val(:electron), final_uri; window)
    elseif frontend ∉ (:browser, :none)
        create_frontend(Val(frontend), final_uri; timeout, electron_options, frontend_options...)
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
    
    app = App(model, frontend_instance, normalize_priority(priority), id, "$uri", Dict{String, Any}(electron_options), float(timeout), port, Dict{Symbol, Any}(frontend_options))
    if model === nothing && frontend_instance === nothing
        @warn("App has neither frontend nor backend")
        return app
    end
    print("Waiting for App to be ready ")
    t0 = time()
    dt = time() - t0
    # an unconnected client has no model fields yet, so errors count as "not ready"
    app_ready() = try isready(app) === true catch; false end
    while !app_ready() && dt < timeout
        delay = dt < 1 ? 0.1 : 1
        sleep(delay)
        delay > 1 && print('.')
        dt = time() - t0
    end
    println()

    if !app_ready()
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
        frontend::Symbol = app.__frontend__ === nothing ? :none : frontend_kind(app.__frontend__),
        isready::Function = app -> app.isready === true,
        electron_options::Dict{String, <:Any} = app.__electron_options__,
        priority::Symbol = app.__priority__,
        window = frontend_window(app.__frontend__),
        frontend_options::AbstractDict{Symbol} = app.__frontend_options__
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
- `frontend::Symbol`: Frontend type (`:electron`, `:browser`, `:client`, or `:none`).
- `isready::Function`: Function to check if the backend is ready.
- `electron_options::Dict{String, <:Any}`: Options for the Electron window.
- `priority::Symbol`: Where properties are read and written if both a backend model and a frontend are available (`:backend` or `:frontend`).
- `window`: Existing Electron window to reuse.
- `frontend_options::AbstractDict{Symbol}`: Options passed on to the frontend, e.g. `:profile` and `:headless` for `:playwright`.

# Returns
The modified `App` instance.
"""
function App(app::App, args...;
    timeout::Real = app.__timeout__,
    port = app.__port__,
    id::String = app.__id__,
    backend::Bool = app.__model__ !== nothing,
    frontend::Symbol = app.__frontend__ === nothing ? :none : frontend_kind(app.__frontend__),
    isready::Function = app -> app.isready === true,
    electron_options::Dict{String, <:Any} = app.__electron_options__,
    priority::Symbol = app.__priority__,
    window = frontend_window(app.__frontend__),
    frontend_options::AbstractDict{Symbol} = app.__frontend_options__
)
    a = App(args...; timeout, port, id, backend, frontend, isready, electron_options, priority, window, frontend_options)
    for field in fieldnames(App)
        setfield!(app, field, getfield(a, field))
    end
    app
end

macro App()
    :(App(@__MODULE__))
end

function Base.propertynames(app::App)
    target = access_target(app)
    if target === :model
        tuple(propertynames(app.__model__)..., fieldnames(App)...)
    elseif target === :frontend && app.__frontend__ isa Client
        tuple(propertynames(app.__frontend__)..., fieldnames(App)...)
    elseif target === :frontend
        tuple(model_fieldnames(app.__frontend__)..., fieldnames(App)...)
    else
        fieldnames(App)
    end
end

function Base.run(app::App, msg::Union{AbstractString, JSONText}; timeout = 1, clone_result::Union{Bool, Nothing} = true)
    frontend = app.__frontend__
    if frontend !== nothing && has_js(frontend)
        eval_js(frontend, msg; clone_result)
    elseif app.__model__ !== nothing
        read(app.__model__, msg; timeout)
    elseif frontend isa Client
        error("JavaScript evaluation is not supported by the headless Client frontend.")
    end
end

function Base.close(app::App)
    frontend = app.__frontend__
    if frontend === nothing
        # a page opened in the default browser can only be closed from the inside
        app.__model__ !== nothing && run(app.__model__, "window.close()")
    else
        # The frontend closes its own window. Closing the page from the inside as well would destroy the
        # window behind the back of the frontend, which then sends a command for a window that is gone.
        close(frontend)
    end
    nothing
end

function print_object(io, app::App, compact = false)
    println(io, "Instance of 'GenieTest.App'")
    compact && return
    
    if app.__model__ === nothing
        println(io, "    backend:  nothing")
    else
        print(io, "    backend:  ")
        show(io, app.__model__)
        println(io)
    end
    frontend = app.__frontend__
    print(io, "    frontend: ")
    if frontend !== nothing
        show(io, frontend)
        println(io)
    else
        println(io, "nothing")
    end
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

"""
    trigger_event(app::App, event, info = nothing; via = :auto)

Trigger a Stipple event (see `@event`), i.e. call the handler `notify(model, Val(event), info)`.

`via` selects the path:
- `:backend`: the handler is called directly on the backend model.
- `:frontend`: the event is sent from the frontend, as a UI element would do it
  (`handle_event` in an Electron `Window`, an `events` WebChannel message for a `Client`).
  This tests the full round trip.
- `:auto` (default): `:frontend` or `:backend` according to the app's access priority
  (see `App`), falling back to the one that is available.

Returns `true` if the event was dispatched. Frontend events are handled asynchronously,
use [`wait_for`](@ref) to wait for their effects.
"""
function trigger_event(app::App, event::Union{Symbol, AbstractString}, info = nothing; via::Symbol = :auto)
    via ∈ (:auto, :backend, :frontend) || throw(ArgumentError("via must be :auto, :backend or :frontend, got :$via"))
    model = getfield(app, :__model__)
    frontend = getfield(app, :__frontend__)
    frontend_usable = frontend !== nothing && is_usable(frontend)

    if via === :auto
        via = access_target(app) === :frontend ? :frontend : model !== nothing ? :backend : :frontend
    end

    if via === :backend
        model === nothing && error("App has no backend model to trigger event $event.")
        notify(model, Val(Symbol(event)), info)
        true
    elseif frontend_usable
        trigger_event(frontend, event, info)
    else
        error("App has no usable frontend to trigger event $event.")
    end
end

"""
    wait_for(f; success = true, fail = false, timeout = 10, delay = 0.05)
    wait_for(f, app::App; kwargs...)

Wait until `f()` is true. Returns `success`, or `fail` if the timeout expires.
For an `App` with a headless `Client` frontend the wait is event driven (`delay` is ignored),
otherwise (or if the app has a backend model) `f` is polled every `delay` seconds.
"""
function wait_for(f; success = true, fail = false, timeout::Real = 10, delay::Real = 0.05)
    t0 = time()
    while time() < t0 + timeout
        f() && return success
        sleep(delay)
    end
    f() ? success : fail
end

function wait_for(f, app::App; kwargs...)
    frontend = getfield(app, :__frontend__)
    # with a backend model, changes are not pushed through the client, so poll
    if frontend isa Client && getfield(app, :__model__) === nothing
        wait_for(f, frontend; kwargs...)
    else
        wait_for(f; kwargs...)
    end
end

function notify_test(model::ReactiveModel, test::Test.Result, test_str::AbstractString = "Test"; kwargs...)
    success = test isa Test.Pass
    notify(model, "$test_str $(success ? "succeeded!" : "failed!")", type = success ? "positive" : "negative"; kwargs...)
end

function notify_test(client::Client, test::Test.Result, test_str::AbstractString = "Test"; kwargs...)
    success = test isa Test.Pass
    notify(client, test_str * (success ? " succeeded!" : " failed!"))
end

function notify_test(app::App, test::Test.Result, test_str::AbstractString = "Test"; kwargs...)
    if app.__model__ !== nothing
        notify_test(app.__model__, test, test_str; kwargs...)
    elseif app.__frontend__ !== nothing
        notify_test(app.__frontend__, test, test_str; kwargs...)
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
    if app.__frontend__ isa Client
        close(app.__frontend__)
        App(app, uri)
    elseif run(app, "window.location = '$final_uri'") === nothing
        App(app, final_uri)
    end
    return app
end

reload(app::App) = redirect!(app, app.__url__)

"""
    goto(app::App, url::Union{String, URI}; id = app.__id__)

Navigate the app to a new URL by directly setting the window location.

Unlike `redirect!`, this function does not update the app's internal state and performs
a simple navigation by setting the window location. The URL is not merged with the base URL.
For a headless `Client` frontend the client is closed and reconnected to the new page
(relative URLs are resolved against the app's URL), while the app's stored URL and id are kept.

# Arguments
- `app::App`: The app instance to navigate.
- `url::Union{String, URI}`: The URL to navigate to.

# Keyword Arguments
- `id = app.__id__`: Debug ID to append to the URL. Defaults to the current app ID.

# Returns
The result of the JavaScript execution (typically `nothing`).
"""
function goto(app::App, url::Union{String, URI}; id = app.__id__)
    if app.__frontend__ isa Client
        # a headless client has no window.location, so it reconnects to the new page;
        # like for a window, the app's stored url and id stay untouched
        stored_url, stored_id = app.__url__, app.__id__
        close(app.__frontend__)
        App(app, merge_uri(URI(stored_url), URI(url)); id)
        app.__url__, app.__id__ = stored_url, stored_id
        return nothing
    end
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
    app.__model__ === nothing && app.__frontend__ isa Client && return is_connected(app.__frontend__)
    try
        run(app, "window?.GENIEMODEL?.isready || false")
    catch
        try
            app.isready === true
        catch
            false
        end
    end
end

"""
    assert_connection!(app::App; timeout = nothing, port = nothing, isready::Function = app -> app.isready === true)

Ensure the app is connected: recreate the window if it has been closed, or (re)connect
a headless client if it is not connected. Setting up an `App` never requires the
connection to succeed, this function is the place to assert it.

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
function assert_connection!(app::App; timeout = nothing, port = nothing, isready::Function = app -> app.isready === true)
    if app.__frontend__ isa Client
        connect!(app.__frontend__; timeout = timeout === nothing ? app.__timeout__ : timeout)
    elseif app.__frontend__ isa AbstractFrontend
        if !is_usable(app.__frontend__)
            @info "App window appears to be closed. Recreating the window..."
            try
                cleanup!(app.__frontend__)
                a = App(
                    app.__url__,
                    id = app.__id__,
                    frontend = frontend_kind(app.__frontend__),
                    electron_options = app.__electron_options__,
                    frontend_options = app.__frontend_options__,
                    priority = app.__priority__,
                    backend = app.__model__ !== nothing,
                    timeout = timeout === nothing ? app.__timeout__ : timeout,
                    port = port === nothing ? app.__port__ : port,
                )
                app.__model__ = a.__model__
                app.__frontend__ = a.__frontend__
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

"""
    connect!(app::App; kwargs...)

Alias of [`assert_connection!`](@ref). It is public but not exported, because other packages
(e.g. Playwright) export a `connect!` as well.
"""
connect!(app::App; kwargs...) = assert_connection!(app; kwargs...)

"""
    get_html(app::App, selector, index::Integer = 1; default = "")

Get the HTML content of a DOM element matching the CSS selector.

This function queries the frontend DOM and retrieves the HTML content of an element
that matches the given CSS selector. When `index = 1`, it uses `querySelector` to get
the first matching element. When `index > 1`, it uses `querySelectorAll` to select
the element at the specified position (1-based indexing).

# Arguments
- `app::App`: The app instance to query.
- `selector`: CSS selector string to identify the target element(s).
- `index::Integer = 1`: The position of the element to select when multiple elements match (1-based).

# Keyword Arguments
- `default = "failed"`: Default value to return if the element is not found or the query fails.

# Returns
The HTML content of the matched element as a string, or the `default` value if not found.

# Example
```julia
button_label = get_html(app, ".q-dialog .q-btn__content > span", default = "")
second_button = get_html(app, "button", 2, default = "")
```
"""
function get_html(app::App, selector, index::Integer = 1; default = "")
    qs = index == 1 ? "querySelector('$selector')" : "querySelectorAll('$selector')?.[$index - 1]"
    run(app, js"""window.document.$qs?.getHTML() || '$default'"""i, clone_result = false)
end

"""
    click(app::App, selector, index::Integer = 1)

Simulate a click event on a DOM element matching the CSS selector.

This function finds an element in the frontend DOM that matches the given CSS selector
and programmatically triggers a click event on it. When `index = 1`, it uses `querySelector`
to get the first matching element. When `index > 1`, it uses `querySelectorAll` to select
the element at the specified position (1-based indexing).

# Arguments
- `app::App`: The app instance containing the frontend.
- `selector`: CSS selector string to identify the target element(s).
- `index::Integer = 1`: The position of the element to click when multiple elements match (1-based).

# Returns
`true` if the element was found and clicked, `false` otherwise.

# Examples
```julia
click(app, "button")
click(app, "button", 2)  # Click the second button matching the selector
click(app, ".q-tree__arrow")
```
"""
function click(app::App, selector, index::Integer = 1)
    qs = index == 1 ? "querySelector('$selector')" : "querySelectorAll('$selector')?.[$index - 1]"
    run(app, js"""(el => !!el && !el.click())(document.$qs)"""i, clone_result = false)
end

toggle_devtools(app::App) = app.__frontend__ !== nothing && toggle_devtools(app.__frontend__)

end # GenieTest