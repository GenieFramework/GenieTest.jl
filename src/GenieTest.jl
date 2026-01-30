module GenieTest

using Test
export App, wait_for, notify_test

using Reexport
@reexport using Stipple
@reexport using Stipple.ReactiveTools

using Electron
using UUIDs

struct App
    __model__::Union{ReactiveModel, Nothing}
    __window__::Union{Window, Nothing}
    __priority__::Base.RefValue{Symbol}
end

App(model::Union{ReactiveModel, Nothing}, window::Union{Window, Nothing}, priority::Symbol = :model) = App(model, window, Ref(:model))

"""
    unproxy(msg::String)

Workaround for a JS Error in Electron when parsing proxy objects.
"""
function unproxy(msg::String)
    "(x => (window.Vue) && Vue.isProxy(x) ? JSON.parse(JSON.stringify(x)) : x)($msg)"
end

function Base.getproperty(app::App, fieldname::Symbol)
    fieldname ∈ [:__model__, :__window__, :__priority__] && return getfield(app, fieldname)

    if app.__priority__[] == :window && app.__window__ !== nothing
        run(app.__window__, unproxy("GENIEMODEL['$fieldname']"))
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
    elseif app.__window__ !== nothing
        try
            run(app.__window__, unproxy("GENIEMODEL['$fieldname']"))
        catch _
            nothing
        end
    else
        @warn("App has neither model nor window")
    end
end

function Base.setproperty!(app::App, fieldname::Symbol, value)
    if app.__priority__[] == :window && app.__window__ !== nothing
        js_value = json(render(value))
        run(app.__window__, unproxy("GENIEMODEL['$fieldname'] = $js_value"))
    elseif app.__model__ !== nothing
        field = getfield(app.__model__, fieldname)
        if field isa Reactive
            field[] = value
        else
            setfield!(app.__model__, fieldname, value)
        end
    elseif app.__window__ !== nothing
        js_value = json(render(value))
        run(app.__window__, unproxy("GENIEMODEL['$fieldname'] = $js_value"))
    else
        @warn("App has neither model nor window")
    end
end

Base.getindex(app::App, fieldname::Symbol) = getproperty(app, fieldname::Symbol)

function Base.setindex!(app::App, value, fieldname::Symbol)
    app.__model__ === nothing && return
    field = getfield(app.__model__, fieldname)
    if field isa Reactive
        getfield(field, :o).val = value
    else
        setfield!(app.__model__, fieldname, value)
    end
end

# Will be moved to Stipple, therefore adding it here as a Union to prevent overwrite error.
Base.getindex(model::Union{Nothing, ReactiveModel}, field::Symbol) = model === nothing ? nothing : getfield(model, field)

Base.notify(app::App, field::Symbol) = app.__model__ !== nothing && notify(getfield(app.__model__, field))
Base.notify(app::App, msg::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...) = app.__model__ !== nothing && notify(app.__model__, msg, type; kwargs...)

"""
    App(url::String = "/";
    timeout::Int = 30,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = :browser,
    backend::Bool = !startswith(url, r"https://"i),
    isready::Function = app -> app.isready
)

Create a Stipple App with optional frontend and backend.
# Arguments
- `url::String = "/"`: URL to open in the frontend. If it does not start with
  "http://" or "https://", it is assumed to be "http://localhost:port/".
# Keyword Arguments
- `timeout::Int = 10`: Timeout in seconds to wait for the backend to be ready.
- `port = nothing`: Port where the Genie server is running. If `nothing`,
  it uses `Genie.config.server_port`.
- `id::String = string(uuid4())`: Debug ID used to identify the Stipple model
  in the backend.
- `frontend::Symbol = :browser`: Frontend to use. Can be `:browser`, `:electron`,
  or `:none`. If `:browser`, it opens the URL in the default browser. If `:electron`, it
  opens an Electron window. If `:none`, it does not open any frontend.
- `backend::Bool = true`: Whether to start the backend Stipple model. If `false`,
  only the frontend is started. This can be useful for testing remote apps.
- `backend_ready::Function = model -> model.isready[]`: Function to check if the
  backend is ready. It takes the Stipple model as argument and should return
  `true` if the backend is ready. By default, it checks the `isready` field
  of the model.
# Returns
An `App` instance containing the backend model and the frontend window.
"""
function App(url::String;
    timeout::Int = 10,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = :browser,
    backend::Bool = !startswith(url, r"https://"i),
    isready::Function = app -> app.isready === true,
    electron_options::Dict{String, <:Any} = Dict{String, Any}()
)
    port === nothing && (port = Genie.config.server_port)
    println()
    @info "--------------   Starting App --------------"
    startswith(url, r"https?://"i) || (url = "http://localhost:$port/" * strip(url, '/'))
    url = URI("$url?debug_id=$id")
    win = if frontend == :electron
        # default to sandbox mode
        electron_options = Dict{String, Any}(electron_options)
        wp = get!(electron_options, "webPreferences", Dict{String, Any}())
        electron_options["webPreferences"] = merge(Dict{String, Any}("sandbox" => true), wp)

        Window(url, options = electron_options)
    elseif frontend == :browser
        Genie.Server.openbrowser(url)
        nothing
    else
        HTTP.get(url)
        nothing
    end
    model = nothing
    if backend
        model = Stipple.debug_model(id; timeout)
        frontend == :none && (model.isready[] = true)
    end
    
    app = App(model, win)

    t0 = time()
    print("Waiting for App to be ready ")
    while !isready(app) && time() < t0 + timeout
        sleep(1)    
        print('.')
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
    return App(model, nothing)
end

App(context::Module) = App(@eval context Stipple.@type)

function Base.run(app::App, msg::Union{String, JSONText})
    msg isa JSONText && (msg = json(msg))
    if app.__window__ !== nothing
        run(app.__window__, unproxy(msg))
    elseif app.__model__ !== nothing
        run(app.__model__, msg)
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

function notify_test(app::App, test::Test.Result, test_str::AbstractString = "Test")
    notify_test(app.__model__, test, test_str)
end

end # GenieTest