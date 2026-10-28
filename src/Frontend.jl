"""
    AbstractFrontend

Supertype of everything an [`App`](@ref) can use as its frontend: the headless [`Client`](@ref)
and browser based frontends like the Electron window (`ElectronFrontend`).

A frontend implements:
- `frontend_kind(f)::Symbol`: the name used for the `frontend` keyword of `App` (e.g. `:electron`).
- `create_frontend(Val(kind), uri; kwargs...)`: construct it.
- `Base.close(f)`.

and optionally overrides
- `is_usable(f)` (default `true`): whether the frontend can currently be used, e.g. its window still exists.
- `has_js(f)` (default `true`): whether JavaScript can be evaluated. A frontend with `has_js(f) == true`
  must implement `eval_js(f, code; clone_result)`, all other operations on the model in the browser
  (`f[index]`, `notify`, `trigger_event`, ...) are derived from it.
"""
abstract type AbstractFrontend end

"""
    JSFrontend <: AbstractFrontend

Supertype of frontends that run in a browser and evaluate JavaScript (Electron, and Playwright once it is available).
Their model fields are available with dot syntax, `frontend.myfield` and `frontend.myfield = value`,
including completion of the field names. Internal fields of such a frontend are named `__field__`.
"""
abstract type JSFrontend <: AbstractFrontend end

is_usable(::AbstractFrontend) = true
has_js(::AbstractFrontend) = true

function frontend_kind end

"""
    cleanup!(frontend)

Release the resources of a frontend that is no longer usable, before it is replaced by a new one
(see `assert_connection!`). Does nothing by default.
"""
cleanup!(::AbstractFrontend) = nothing

"""
    create_frontend(::Val{kind}, uri; kwargs...)

Create a frontend of the given kind (see [`frontend_kind`](@ref)) that loads `uri`.
Frontends provided by package extensions only get a method once the extension is loaded.
"""
create_frontend(::Val{kind}, args...; kwargs...) where kind =
    error("Frontend :$kind is not available. Is the package that provides it loaded?")

"""
    unproxy(msg::String)

Workaround for a JS Error in Electron when parsing proxy objects.
"""
function unproxy(msg::String)
    "(x => (window.Vue) && Vue.isProxy(x) ? JSON.parse(JSON.stringify(x)) : x)($msg)"
end

"""
    js_clone(msg::String)

Workaround for a JS Error in Electron when parsing proxy objects.
"""
function js_clone(msg::String)
    "JSON.parse(JSON.stringify($msg))"
end

"""
    eval_js(frontend, code::Union{AbstractString, JSONText}; clone_result = false)

Evaluate JavaScript `code` in the frontend and return the result. `clone_result` is a hint for
frontends that cannot transfer Vue proxy objects: `true` clones the result (`JSON.parse(JSON.stringify(...))`),
`nothing` clones only if necessary, `:unproxy` unwraps Vue proxies and `false` does nothing.
"""
function eval_js(f::AbstractFrontend, code::Union{AbstractString, JSONText}; clone_result = false)
    has_js(f) && error("eval_js is not implemented for $(typeof(f)).")
    error("JavaScript evaluation is not supported by the $(frontend_label(f)) frontend.")
end

frontend_label(f::AbstractFrontend) = string(frontend_kind(f))

function require_js(f::AbstractFrontend)
    has_js(f) || error("JavaScript property access requires a frontend with JavaScript support (like an Electron window), not the $(frontend_label(f)) frontend.")
    f
end

function model_path(index::Union{AbstractString, JSONText})
    index isa JSONText && (index = json(index))
    startswith(index, '[') ? index : ".$index"
end

function Base.getindex(f::AbstractFrontend, index::Union{AbstractString, JSONText})
    require_js(f)
    eval_js(f, "GENIEMODEL$(model_path(index))"; clone_result = :unproxy)
end

function Base.setindex!(f::AbstractFrontend, val, index::Union{AbstractString, JSONText})
    require_js(f)
    index = model_path(index)
    js_value = json(render(val))
    code = if endswith(index, r"juliaGet\(\d+\)")
        index = replace(index, r"juliaGet\((\d+)\)$" => s"juliaSet(\1")
        "window?.GENIEMODEL$index, $js_value)"
    else
        """window?.GENIEMODEL.setField("$index", $js_value)"""
    end
    eval_js(f, code; clone_result = :unproxy)
end

"""
    get_model_field(frontend, fieldname::Symbol)

Read a model field as the frontend sees it.
"""
get_model_field(f::AbstractFrontend, fieldname::Symbol) =
    eval_js(require_js(f), "window?.GENIEMODEL?.$fieldname"; clone_result = :unproxy)

"""
    set_model_field!(frontend, fieldname::Symbol, value)

Write a model field in the frontend (and, through the reactive connection, in the backend).
"""
function set_model_field!(f::AbstractFrontend, fieldname::Symbol, value)
    js_value = json(render(value))
    eval_js(require_js(f), "GENIEMODEL.$fieldname = $js_value"; clone_result = :unproxy)
end

"""
    model_fieldnames(frontend)

Names of the model fields the frontend knows about. They are read from `$data`, because a production build
of Vue only exposes the internal `_` on the instance itself.
"""
function model_fieldnames(f::AbstractFrontend)
    fnames = eval_js(require_js(f), """
        (x => Object.keys(x.\$data || x).filter(k => typeof x[k] !== 'function' && k !== 'WebChannel'))(window?.GENIEMODEL || {})
        """; clone_result = false)
    fnames === nothing ? Symbol[] : Symbol.(fnames)
end

function Base.notify(f::AbstractFrontend, field::Symbol, priorities = nothing)
    priorities === Stipple.ReactiveTools.NO_NOTIFY && return false

    # no listener priorities available on the client side, so only evaluate priorities for level 0
    priorities isa Function && priorities(0) === false && return false

    eval_js(f, "window?.GENIEMODEL?.push('$field')")
end

function Base.notify(f::AbstractFrontend, message::AbstractString, type::Union{Nothing, String, Symbol} = nothing; kwargs...)
    d = Stipple.opts(;type, message, kwargs...)
    js_dict = strip(json(d), '"')
    eval_js(f, js"""window?.GENIEMODEL?.\$q.notify($js_dict); null"""i)
end

function notify_test(f::AbstractFrontend, test::Test.Result, test_str::AbstractString = "Test"; kwargs...)
    success = test isa Test.Pass
    notify(f, "$test_str $(success ? "succeeded!" : "failed!")", type = success ? "positive" : "negative"; kwargs...)
end

"""
    trigger_event(frontend, event, info = nothing)

Send a Stipple event from the frontend as a UI element would do it.
"""
function trigger_event(f::AbstractFrontend, event::Union{Symbol, AbstractString}, info = nothing)
    eval_js(require_js(f), "window.GENIEMODEL.handle_event($(json(render(info))), $(json(String(event)))); null")
    true
end

"""
    goto!(frontend, url)

Navigate the frontend to `url`. Frontends with JavaScript support do this through `window.location`.
"""
goto!(f::AbstractFrontend, url) = eval_js(require_js(f), "window.location = '$url'")

"""
    frontend_window(frontend)

The Electron window of an Electron frontend, `nothing` for all other frontends.
"""
frontend_window(::Union{Nothing, AbstractFrontend}) = nothing

"""
    as_frontend(x)

Convert `x` (e.g. an `Electron.Window`) to a frontend. Frontends are returned unchanged.
"""
as_frontend(f::Union{Nothing, AbstractFrontend}) = f
as_frontend(x) = throw(ArgumentError("Cannot use $(typeof(x)) as a frontend."))

"""
    toggle_devtools(app)

Toggle the developer tools of a frontend that has them (Electron).
"""
function toggle_devtools end
toggle_devtools(::AbstractFrontend) = false

is_internal(name::Symbol) = (n = String(name); startswith(n, "__") && endswith(n, "__"))

function Base.getproperty(f::JSFrontend, name::Symbol)
    is_internal(name) ? getfield(f, name) : get_model_field(f, name)
end

function Base.setproperty!(f::JSFrontend, name::Symbol, value)
    is_internal(name) ? setfield!(f, name, value) : set_model_field!(f, name, value)
end

function Base.propertynames(f::JSFrontend, private::Bool = false)
    fields = is_usable(f) ? Tuple(model_fieldnames(f)) : ()
    private ? (fields..., fieldnames(typeof(f))...) : fields
end
