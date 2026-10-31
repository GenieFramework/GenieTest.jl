module GenieTestPlaywrightExt

using GenieTest
using GenieTest: AbstractFrontend, JSFrontend, JSONText, json
using Playwright

import GenieTest: frontend_kind, is_usable, eval_js, create_frontend, cleanup!, unproxy, js_clone

const DEFAULT_ENGINES = ["chrome", "msedge", "chromium"]
const DEFAULT_PROFILE = joinpath(homedir(), ".julia", "playwright-profile")

# A browser profile can only be used by one browser process. Launching a second browser on the same profile
# just opens a tab in the running one and exits, so all frontends on a profile share one browser (and driver).
mutable struct Session
    key::String
    pw::Playwright.PlaywrightAPI
    context::Playwright.BrowserContext
    frontends::Int
end

const SESSIONS = Dict{String, Session}()
const SESSIONS_LOCK = ReentrantLock()

"""
    PlaywrightFrontend

Frontend that shows the app in a page (tab) of a browser driven by Playwright. Frontends that use the same
profile share the browser; the browser is closed together with its last frontend.
"""
mutable struct PlaywrightFrontend <: JSFrontend
    __pw__::Playwright.PlaywrightAPI
    __context__::Playwright.BrowserContext
    __page__::Playwright.Page
    __session__::Session
end

frontend_kind(::PlaywrightFrontend) = :playwright

# Playwright has no `is_closed` for pages, but a context only lists its open pages
function is_usable(f::PlaywrightFrontend)
    try
        f.__page__ in Playwright.pages(f.__context__)
    catch
        false
    end
end

function close_session(session::Session)
    try Playwright.close!(session.context) catch end
    try Playwright.shutdown(session.pw) catch end
    lock(SESSIONS_LOCK) do
        get(SESSIONS, session.key, nothing) === session && delete!(SESSIONS, session.key)
    end
end

function Base.close(f::PlaywrightFrontend)
    session = f.__session__
    last = lock(SESSIONS_LOCK) do
        # closing twice must not release the browser of another frontend
        session.frontends > 0 || return false
        session.frontends -= 1
        session.frontends == 0
    end
    if last
        close_session(session)
    else
        try Playwright.close!(f.__page__) catch end
    end
    nothing
end

cleanup!(f::PlaywrightFrontend) = close(f)

function Base.show(io::IO, f::PlaywrightFrontend)
    print(io, "Playwright.Page(", is_usable(f) ? "open" : "closed", ")")
end

# Playwright returns every JavaScript number as a Float64 and `undefined` as `missing`.
normalize(x) = x
normalize(x::Missing) = nothing
normalize(x::AbstractFloat) = isinteger(x) && abs(x) < 2^53 ? Int(x) : x
normalize(x::AbstractVector) = Any[normalize(v) for v in x]
normalize(x::AbstractDict) = Dict{String, Any}(String(k) => normalize(v) for (k, v) in x)

function eval_js(f::PlaywrightFrontend, code::Union{AbstractString, JSONText}; clone_result = false)
    if !is_usable(f)
        @warn "Cannot run code in the browser page, it probably has been closed."
        return nothing
    end
    code = String(code isa JSONText ? json(code) : code)
    if clone_result === true
        code = js_clone(code)
    elseif clone_result === :unproxy
        code = unproxy(code)
    end
    normalize(Playwright.evaluate(f.__page__, code))
end

"""
    create_frontend(Val(:playwright), uri; profile, headless, engine, launch_options...)

Start a Playwright browser on the persistent profile directory `profile` and load `uri`.

- `profile = joinpath(homedir(), ".julia", "playwright-profile")`: the browser profile. It keeps logins
  (e.g. SSO/passkeys) between runs. A profile can only be used by one browser process, therefore all apps with
  the same profile share one browser and each gets its own tab (the options of the first app apply).
  The browser is closed with the last app. `nothing` uses a separate temporary profile.
- `headless = false`: show the browser window.
- `engine = ["chrome", "msedge", "chromium"]`: the engine(s) passed to `Playwright.engine`, tried in order until
  one can be launched. `"chrome"` and `"msedge"` use an installed Google Chrome / Microsoft Edge, `"chromium"` is
  the browser binary that Playwright downloads itself (`Playwright.install(browsers = ["chromium"])`; it is also
  fetched on demand if possible). Passkeys and platform authenticators need a real Chrome or Edge.

- `chromium_sandbox = true`: keep Chromium's sandbox. Playwright's default (`false`) starts Chrome with `--no-sandbox`,
  which makes Chrome show an "unsupported command-line flag" warning.

Further options are passed to `Playwright.launch_persistent_context`.
"""
function create_frontend(::Val{:playwright}, uri;
    profile::Union{AbstractString, Nothing} = DEFAULT_PROFILE,
    headless::Bool = false,
    engine::Union{AbstractString, AbstractVector{<:AbstractString}} = DEFAULT_ENGINES,
    chromium_sandbox::Bool = true,
    timeout = 30,
    electron_options = nothing,
    launch_options...
)
    engines = engine isa AbstractString ? [engine] : collect(String, engine)
    profile === nothing && (profile = mktempdir())
    mkpath(profile)
    key = realpath(profile)
    lock(SESSIONS_LOCK) do
        session = get(SESSIONS, key, nothing)
        # a browser that has been closed by the user has no pages left
        if session !== nothing && isempty(session_pages(session))
            @info "The browser of profile $key has been closed, starting a new one."
            delete!(SESSIONS, key)
            @async close_session(session)
            session = nothing
        end
        if session === nothing
            pw = Playwright.start_playwright()
            try
                ctx = launch_context(pw, engines, profile; headless, chromium_sandbox, launch_options...)
                session = SESSIONS[key] = Session(key, pw, ctx, 0)
                # a persistent context comes with a page, which is used by the first frontend
                page = first(Playwright.pages(ctx))
                return new_frontend(session, page, uri)
            catch
                try Playwright.shutdown(pw) catch end
                delete!(SESSIONS, key)
                rethrow()
            end
        end
        new_frontend(session, Playwright.new_page(session.context), uri)
    end
end

function launch_context(pw, engines, profile; kwargs...)
    errors = Pair{String, Any}[]
    for name in engines
        try
            return Playwright.launch_persistent_context(Playwright.engine(pw, name), profile; kwargs...)
        catch e
            push!(errors, name => e)
            length(engines) > 1 && @info "Could not launch Playwright engine \"$name\", trying the next one." exception = e
        end
    end
    length(errors) == 1 && throw(last(only(errors)))
    error("None of the Playwright engines $(join(repr.(engines), ", ")) could be launched. " *
        "Install Chrome or Edge, or run `Playwright.install(browsers = [\"chromium\"])`.")
end

session_pages(session::Session) = try Playwright.pages(session.context) catch; Playwright.Page[] end

function new_frontend(session::Session, page, uri)
    session.frontends += 1
    try
        Playwright.goto!(page, string(uri))
    catch
        session.frontends -= 1
        rethrow()
    end
    PlaywrightFrontend(session.pw, session.context, page, session)
end

end # module
