module GenieTest

using Test
export wait_for, notify_test

using Electron
using Stipple, Stipple.ReactiveTools
using UUIDs
using HTTP
using Dates

struct App
    model::Union{ReactiveModel, Nothing}
    window::Union{Window, Nothing}
end

function Base.getproperty(app::App, fieldname::Symbol)
    if app[:model] !== nothing
        model = app[:model]
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
    elseif app[:window] !== nothing
        run(app[:window], "GENIEMODEL['$fieldname']")
    else
        @warn("App has neither model nor window")
    end
end

function Base.setproperty!(app::App, fieldname::Symbol, value)
    if app[:model] !== nothing
        field = getfield(app[:model], fieldname)
        if field isa Reactive
            field[] = value
        else
            setfield!(app[:model], fieldname, value)
        end
    elseif app[:window] !== nothing
        js_value = json(render(value))
        run(app[:window], "GENIEMODEL['$fieldname'] = $js_value")
    else
        @warn("App has neither model nor window")
    end
end

Base.getindex(app::App, fieldname::Symbol) = getfield(app, fieldname)

function Base.setindex!(app::App, value, fieldname::Symbol)
    app[:model] === nothing && return
    field = getfield(app[:model], fieldname)
    if field isa Reactive
        getfield(field, :o).val = value
    else
        setfield!(app[:model], fieldname, value)
    end
end

# will be moved to Stipple
Base.getindex(model::ReactiveModel, field::Symbol) = getfield(model, field)

Base.notify(app::App, field::Symbol) = app[:model] !== nothing && notify(getfield(app[:model], field))

"""
    App(url::String = "/";
    timeout::Int = 30,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = :browser,
    backend::Bool = true,
    backend_ready::Function = model -> model.isready[]
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
function App(url::String = "/";
    timeout::Int = 10,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = :browser,
    backend::Bool = true,
    backend_ready::Function = model -> model.isready[]
)
    port === nothing && (port = Genie.config.server_port)
    println()
    @info "--------------   Starting App --------------"
    startswith(url, r"https?://"i) || (url = "http://localhost:$port/" * strip(url, '/'))
    url = URI("$url?debug_id=$id")
    win = if frontend == :electron
        Window(url, options = Dict("sandbox" => true))
    elseif frontend == :browser
        Genie.Server.openbrowser(url)
        nothing
    else
        HTTP.get(url)
        nothing
    end
    model = nothing
    if backend
        t0 = time()
        model = Stipple.debug_model(id; timeout)
        frontend == :none && (model.isready[] = true)

        while time() < t0 + timeout
            (model === nothing || backend_ready(model)) && break

            @info """
            waiting for App to be ready
                backend_ready: $(backend_ready(model))
            """
            sleep(1)
        end
        println()
        
        if !backend_ready(model)
            close_app(win)
            error("App could not be created")
        end
    end

    @info "App ready"
    return App(model, win)
end

function Base.close(app::App)
    app[:model] !== nothing && run(app[:model], "window.close()")
    app[:window] !== nothing && close(app[:window].app)
end

function print_object(io, app::App, compact = false)
    println(io, "Instance of 'GenieTest.App'")
    compact && return
    
    print(io, "    backend:  ", app[:model] === nothing ? "nothing" : "")
    app[:model] === nothing ? println() : print(app[:model])
    println(io, "    frontend: ", app[:window] === nothing ? "nothing" : "Electron.Window")
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
    notify_test(app[:model], test, test_str)
end

function init_model()
    Stipple.@init(TableViewer, debounce = 50, core_theme = false)
end

end # GenieTest