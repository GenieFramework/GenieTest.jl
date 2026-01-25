# GenieTest

A Julia package for testing Stipple/Genie applications with integrated frontend support.

## Overview

GenieTest provides utilities for creating and testing Stipple-based web applications with both backend (Genie/Stipple reactive models) and frontend (browser or Electron) components. It simplifies the process of launching test applications and verifying their behavior.

The base of the package is the type `App` that behaves very much like a `ReactiveModel` with some subtle differences.
- Values are retrieved from the model, if available, or from an Electron window as a fallback. In that case only public fields are accessible and only fields declared with `@in` are sent to the backend.
- The true fields of the App (`model` and `window` are available via `app[:model]` and `app[:window]`)
- The model fields are available via dot syntax as usual.
- The field values of the App are always values and not Reactive variables. Assignments are nevertheless reactive, e.g. `x = app.myfield` or `app.myfield = "newvalue"`. The reason is that the syntax should be identical independent whether we work with fronend or backend.
- ilent updates are only possible if a model is available and can be written as `app.myfield![!] = "silent update"`. But in most cases you will better define `model = app[:model]`
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
    backend_ready::Function = model -> model.isready[]
)
```

**Arguments:**
- `url`: URL to open (default: "/"). Automatically prefixes with localhost if needed.

**Keyword Arguments:**
- `timeout`: Seconds to wait for backend readiness (default: 10)
- `port`: Server port (default: uses `Genie.config.server_port`)
- `id`: Debug ID for identifying the Stipple model
- `frontend`: Frontend type - `:browser`, `:electron`, or `:none`
- `backend`: Whether to start the backend model (default: true)
- `backend_ready`: Function to check backend readiness

### Frontend Options

```julia
# Open in default browser
app = App("/", frontend = :browser)

# Open in Electron window
app = App("/", frontend = :electron)

# No frontend (headless mode)
app = App("/", frontend = :none, backend = true)

# Frontend only (connect to remote backend)
app = App("https://remote-server.com", backend = false)
```

### Utility Functions

#### wait_for

Wait for a condition to become true with timeout:

```julia
result = wait_for(timeout = 10, delay = 1) do
    app.some_property[] == expected_value
end
```

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
- **Electron**: Desktop application framework
- **HTTP**: HTTP client/server
- **Test**: Julia's testing framework
- **TestItemRunner**: Test execution
- **UUIDs**: Unique identifier generation

### Remarks

- For local testing, the standard browser is probably the best choice. For remote testing Electron must be used, as the standard browser cannot be addressed via JavaScript from the test suite.
- On MacOS Passkeys are, unfortunately, not supported via Electron. (If anyone has a good idea how to get around that limitation, feel welcome to open an issue.)

## License

See [LICENSE](LICENSE) for details.

## Author

Helmut Hänsel <helmut.haensel@gmx.de>
