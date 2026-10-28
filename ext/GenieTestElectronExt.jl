module GenieTestElectronExt

using GenieTest
using GenieTest: AbstractFrontend, JSFrontend, JSONText, json, render, unproxy, js_clone
using Electron
using Electron: Window
using Test

import GenieTest: frontend_kind, is_usable, eval_js, create_frontend, frontend_window, as_frontend, notify_test

abstract type DummyWindow end
Base.run(w::Union{DummyWindow, Window}, code::JSONText) = run(w, json(code))

"""
    ElectronFrontend(window::Electron.Window)

Frontend that shows the app in an Electron window.
"""
struct ElectronFrontend <: JSFrontend
    __window__::Window
end

frontend_kind(::ElectronFrontend) = :electron
is_usable(f::ElectronFrontend) = f.__window__.exists
# Closing must be idempotent: Electron.close(app) closes the windows one by one and the list of windows is updated
# asynchronously, so a second close (or a close racing with the user closing the window) could send a command for a
# window that is already gone, which makes the main process of Electron throw an uncaught exception.
function Base.close(f::ElectronFrontend)
    app = f.__window__.app
    app.exists || return nothing
    try
        close(app)
    catch
        # the application has gone away in the meantime
        app.exists && rethrow()
    end
    nothing
end

function Base.show(io::IO, f::ElectronFrontend)
    print(io, "Electron.Window(", f.__window__.exists ? "open" : "closed", ")")
end

frontend_window(f::ElectronFrontend) = f.__window__
as_frontend(win::Window) = ElectronFrontend(win)

function eval_js(f::ElectronFrontend, msg::Union{AbstractString, JSONText}; clone_result::Union{Bool, Nothing, Symbol} = false)
    win = f.__window__
    if !win.exists
        @warn "Cannot run code on window, it probably has been closed."
        return nothing
    end
    msg isa JSONText && (msg = json(msg))
    msg = String(msg)
    if clone_result === nothing # automatically clone if necessary
        try
            run(win, unproxy(msg))
        catch
            run(win, js_clone(msg))
        end
    elseif clone_result === :unproxy
        run(win, unproxy(msg))
    elseif clone_result === true
        run(win, js_clone(msg))
    else
        run(win, msg)
    end
end

function create_frontend(::Val{:electron}, uri; electron_options = Dict{String, Any}(), window::Union{Window, Nothing} = nothing, kwargs...)
    if window !== nothing && window.exists
        Electron.load(window, uri)
        return ElectronFrontend(window)
    end
    # default to sandbox mode
    electron_options = Dict{String, Any}(electron_options)
    wp = get!(electron_options, "webPreferences", Dict{String, Any}())
    electron_options["webPreferences"] = merge(Dict{String, Any}("sandbox" => true), wp)

    ElectronFrontend(Window(uri, options = electron_options))
end

# kept for backwards compatibility, these operate on the window of an `ElectronFrontend`
Base.getindex(win::Window, index::Union{AbstractString, JSONText}) = getindex(ElectronFrontend(win), index)
Base.setindex!(win::Window, val, index::Union{AbstractString, JSONText}) = setindex!(ElectronFrontend(win), val, index)
Base.notify(win::Window, field::Symbol, priorities = nothing) = notify(ElectronFrontend(win), field, priorities)
Base.notify(win::Window, message::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...) =
    notify(ElectronFrontend(win), message, type; kwargs...)
notify_test(win::Window, test::Test.Result, test_str::AbstractString = "Test"; kwargs...) =
    notify_test(ElectronFrontend(win), test, test_str; kwargs...)

GenieTest.toggle_devtools(f::ElectronFrontend) = Electron.toggle_devtools(f.__window__)

end # module
