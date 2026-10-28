# GenieTest

A Julia package for testing Stipple/Genie applications with integrated frontend support.

## Overview

GenieTest provides utilities for creating and testing Stipple-based web applications with backend (Genie/Stipple reactive models) and frontend (browser, Electron, or headless WebChannel client) support. It simplifies the process of launching test applications and verifying their behavior.

A`GenieTest.App`behaves very much like a `ReactiveModel` with some subtle differences.

- An `App` has a `__model__` backend and a `__frontend__` frontend. The frontend can be `nothing`, an Electron window (`ElectronFrontend`) or a headless `Client` (a Playwright browser is prepared, see below); all are subtypes of `GenieTest.AbstractFrontend`. `__window__` remains as a compatibility alias when the frontend is an Electron `Window`.
- Values are retrieved from the `__model__`, if available, or from the `__frontend__` as a fallback.
- There are currently two possible frontends: an Electron window and a headless native julia client. The latter exposes model fields declared by the page and sends updates through the Genie WebChannel.
- The model fields are available via dot syntax for backend and frontend including auto-completion.
- CAVEAT: The dot syntax always returns values and not Reactive variables. The reason is that the syntax should be identical independent whether we work with fronend or backend. Assignments are nevertheless reactive, e.g. `x = app.myfield` or `app.myfield = "newvalue"` will trigger reactive updates.
- Silent updates are only possible if a model is available and can be written as `app[:myfield] = "silent update`. But in most cases you will better define `model = app.__model__` and continue with standard syntax for `model`
  This syntax is still in development and can be changed in future versions.

## Features

- **Flexible App Creation**: Launch Stipple apps with configurable frontend and backend options
- **Multiple Frontend Options**: Support for browser, Electron, or headless (no frontend) modes
- **Backend Integration**: Automatic connection to Stipple reactive models with timeout handling
- **Property Access**: Convenient dot notation access to reactive model properties
- **Testing Utilities**: Helper functions for waiting and notifications in tests

## Installation

```julia
using Pkg
Pkg.develop(path="path/to/GenieTest")
```

## Usage

### Basic Example

```julia
using Stipple, Stipple.ReactiveTools, StippleUI
using GenieTest

@app begin
    @in x = "World"
    @onchange x @info "new x: $x"
    @onchange isready @info "Ready!"
end

@page "/" [htmldiv("Hello"), textfield("", :x)]

# Create an app with browser frontend, wait for the model to be ready
app = GenieTest.App("/")

# Access reactive model properties
@show app.x

# Set reactive model properties
app.x = "John"

sleep(3)

# Close the app
close(app)
```

### Creating Apps

The `App` constructor provides several configuration options:

```julia
App(url::String = "/";
    timeout::Int = 10,
    port = nothing,
    id::String = string(uuid4()),
    frontend::Symbol = :browser,
    backend::Bool = true,
    isready::Function = app -> app.isready === true,
    priority::Symbol = :backend
)

App(T::Type{ReactiveModel}; kwargs...)

App(context::Module; kwargs)
```

**Arguments:**

- `url`: URL to open (default: `"/"`). Automatically prefixes with localhost if needed.
- `T`: explicit ReactiveModel, e.g. `MyApp`
- `context`: Module name in which an implicit model is defined, e.g. `Main` or `@__MODULE__`

**Keyword Arguments:**

- `timeout`: Seconds to wait for backend readiness (default: 10)
- `port`: Server port (default: uses `Genie.config.server_port`)
- `id`: Debug ID for identifying the Stipple model
- `frontend`: Frontend type - `:browser`, `:electron`, `:client`, or `:none`
- `backend`: Whether to start the backend model (default: `!startswith(url, r"https://"i)`)
- `isready`: Function to check app readiness (default: `app -> app.isready === true`)
- `priority`: `:backend` (default) or `:frontend`. If an app has both a backend model and a frontend
  (`Window` or `Client`), `app.field` and `app.field = value` read and write the model for `:backend` and the
  frontend for `:frontend`. This is useful to attach a backend for inspection and verify what the frontend
  sees, e.g. whether JavaScript execution worked. If only one of them is available, it is used regardless of
  the priority. The priority can be changed later with `app.__priority__ = :frontend`.

### Frontend Options

```julia
# Open in default browser
app = App("/", frontend = :browser)

# Open in Electron window (needs `using Electron`)
app = App("/", frontend = :electron)

# No frontend (headless mode)
app = App("/", frontend = :none, backend = true)

# Headless WebChannel client (no browser window)
app = App("/", frontend = :client, backend = false)

# Frontend only (connect to remote backend)
app = App("https://remote-server.com", backend = false)
```

When no backend model is available, `app.field` reads and `app.field = value` writes
are forwarded to the headless client. The client supports reading and writing model
fields with dot syntax or `getfield_` / `setfield_!`; its model fields are also
available directly as `app.__frontend__.field`. JavaScript and DOM operations require
a frontend with JavaScript support (Electron).

### Playwright (preview)

A `:playwright` frontend that drives a real browser with [Playwright.jl](https://github.com/frankier/playwright-julia)
is prepared in `ext_unregistered/`. It is not a package extension yet, because Playwright.jl is not in the General
registry and a registered package cannot depend on an unregistered one. Meanwhile you can enable it by hand:

```julia
using Pkg
Pkg.add(url = "https://github.com/frankier/playwright-julia")   # once, unregistered

using GenieTest, Playwright
include(joinpath(pkgdir(GenieTest), "ext_unregistered", "GenieTestPlaywrightExt.jl"))

app = App("https://remote-server.com", backend = false, frontend = :playwright)

# headless, with a temporary profile
app = App("/", frontend = :playwright, frontend_options = Dict(:headless => true, :profile => nothing))
```

The `include` only adds methods to GenieTest. Do it once per Julia session, after `using Playwright`, and before the
first `App(...; frontend = :playwright)`. `pkgdir(GenieTest)` works for an installed as well as for a developed GenieTest.

By default it starts the installed Google Chrome (`engine = "chrome"`) with a visible window on a persistent
profile in `joinpath(homedir(), ".julia", "playwright-profile")`. The profile keeps logins between runs (SSO,
passkeys and platform authenticators only work with the real Chrome, not with the bundled Chromium),
but it can only be used by one browser process. Therefore several apps with the same profile share one browser and
each one gets its own tab; the browser is closed together with the last app.

`frontend_options` accepts `:profile`, `:headless`, `:engine`, `:chromium_sandbox` and any other keyword of
`Playwright.launch_persistent_context`. Once Playwright.jl is registered, the `include` will no longer be needed:
`using Playwright` will be enough.

### Connecting

`assert_connection!(app)` ensures that the app is connected to its frontend and returns `true` or
`false` (it never throws). For an Electron window or a Playwright page it recreates a closed one, for a
headless client it (re)connects the client. Creating an `App` does not require the
connection to succeed, so use `assert_connection!(app)` or `is_connected(client)` to assert it.
`GenieTest.connect!(client)` behaves the same way on the client level (`connect!` is public, but not exported,
as it clashes with other packages); `close(client)` disconnects.

### Events

Stipple events (handlers defined with `@event`) are normally triggered by the frontend via
`handle_event(event, 'name')`, which ends up in `notify(model, Val(:name), info)` on the backend.
`trigger_event` triggers them from the test code:

```julia
@event MyApp :ping begin
    pinged += 1
end

trigger_event(app, :ping)                         # path chosen by the app's priority
trigger_event(app, :ping, Dict("a" => 1); via = :backend)   # call the handler directly on the model
trigger_event(app, :ping; via = :frontend)        # send it from the frontend (Electron window or Client)
wait_for(() -> app.pinged == 1, app)              # frontend events are handled asynchronously
```

With `via = :frontend` the full round trip is tested, `via = :backend` only the handler. With the default
`via = :auto` the frontend is used if the app has `priority = :frontend` (or no backend model), otherwise
the backend. A `Client` frontend can also be used directly: `trigger_event(client, :ping, info)`.

### Utility Functions

#### wait_for

Wait for a condition to become true with timeout:

```julia
result = wait_for(timeout = 10, delay = 0.05) do
    app.some_property[] == expected_value
end

# the same with an app: event driven for a headless client without backend model
wait_for(() -> app.condition == "what", app; timeout = 10)
```

Returns `success` (default `true`) or `fail` (default `false`) on timeout. The default polling `delay` is 0.05 s.

#### notify_test

Send test result notifications to the model:

```julia
using Test
result = @test app.value == 42
notify_test(model, result, "Value Check")
```

## Dependencies

- **Genie**: Web framework
- **Stipple**: Reactive UI framework
- **HTTP**: HTTP client/server
- **Test**: Julia's testing framework
- **TestItemRunner**: Test execution
- **UUIDs**: Unique identifier generation

### Remarks

- For local testing, the standard browser is probably the best choice. For remote testing Electron must be used, as the standard browser cannot be addressed via JavaScript from the test suite.
- If you need to evaluate Javascript expressions in the frontend and send them to the backend, Electron is currently more convenient.
- On MacOS Passkeys are, unfortunately, not supported via Electron. A Playwright frontend with the installed Chrome is prepared, see above.
- Electron is optional: `frontend = :electron` needs `using Electron`.

## License

See [LICENSE](LICENSE) for details.

## Author

Helmut Hänsel <helmut.haensel@gmx.de>
