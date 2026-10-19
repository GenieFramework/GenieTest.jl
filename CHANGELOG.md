# Changelog

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
