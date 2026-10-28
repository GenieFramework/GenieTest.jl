# Changelog

## 2.1.0

### Added
- `AbstractFrontend` as the common supertype of all frontends (`Client`, `JSFrontend`). Reading and
  writing model fields, `notify`, `trigger_event` and navigation are defined once on top of `eval_js`.
- `frontend_options` for `App` to pass options on to the frontend.
- A Playwright frontend is prepared in `ext_unregistered/` but not yet part of the package, because
  Playwright.jl is not registered. See the README.
- Dot access to the model fields of browser frontends (`app.__frontend__.field`), including completion
  of the field names.
- `assert_connection!(app)`.

### Changed
- Electron is now a package extension (`GenieTestElectronExt`) and no longer a hard dependency.
  Add `using Electron` to use `frontend = :electron`. `App("https://...")` still defaults to
  Electron and raises an error that says so if Electron is not loaded.
- `connect!(app)` was renamed to `assert_connection!(app)`. `connect!` is still public, but no longer
  exported, because other packages (e.g. Stipple) export a function of that name.
- `isconnected(client)` was renamed to `is_connected(client)`, as it clashed with `Stipple.isconnected`.
- `App.__frontend__` is an `AbstractFrontend` (an `ElectronFrontend` wraps the `Window`).
  `app.__window__` still returns the `Window`.
- An unknown `frontend` now raises an error instead of falling back to an `HTTP.get`.

### Fixed
- Field names of a page that uses a production build of Vue were not found.
- `close(app)` with a backend model and an Electron frontend closed the page from the inside and then sent a
  close command for the already destroyed window, which made the main process of Electron throw and
  `close` hang. The frontend now closes its own window, and closing twice is harmless.

## 2.0.0

### Added
- Headless `Client` frontend (`App(url; frontend = :client)`) that talks to a Stipple
  backend via the Genie WebChannel, without a browser. Model fields can be read and
  written with dot syntax or `getfield_` / `setfield_!`.
- `wait_for(f, app::App; ...)`: event driven for a headless client without backend
  model, polling otherwise.
- `App.__frontend__` (`Window`, `Client` or `nothing`); `__window__` remains as a
  compatibility alias.

- `trigger_event(app, event, info = nothing; via = :auto)` to trigger Stipple events via the
  backend model or from the frontend (Electron window or headless client).

### Changed
- Requires Julia 1.10, Genie 6 and Stipple 1.
- `wait_for` returns `success`/`fail` (default `true`/`false`) on all paths; the default
  polling `delay` changed from 1 s to 0.05 s.
- `connect!(app)` and `connect!(client)` return `true`/`false` instead of throwing, and
  creating an `App` with a client frontend no longer fails if the connection fails.
- Dropped the unused `Dates` dependency.

- `priority` (`:backend` or `:frontend`) is now validated and applies uniformly to
  `Window` and `Client` frontends in `getproperty`, `setproperty!` and `propertynames`.
  `:window` is a deprecated alias for `:frontend`.

### Fixed
- Removed the non-existent `waitfor` export.
- Race conditions when accessing client fields and the client log.
