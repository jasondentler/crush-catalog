# Contributing

Thanks for helping improve Crush Catalog. This project is a Lightroom Classic plugin written in Lua and backed by a local [Wild Catalog service](https://github.com/jasondentler/wild-catalog).

## Development Setup

Install the local test tooling:

```sh
brew install luarocks luajit
make test-deps
make commit-deps
make hooks
```

The test setup uses LuaJIT as a Lua 5.1-compatible runtime because Lightroom Classic's Lua environment is closer to Lua 5.1 than the system Lua installed by Homebrew.

Dependencies are installed into `.lua_modules/`, which is intentionally ignored by Git.

Python development tools are managed with `uv` from `pyproject.toml`. `commitizen` provides the `cz` command for guided Conventional Commits. `pre-commit` installs both normal pre-commit hooks and the `commit-msg` hook from `conventional-pre-commit`.

GitHub Actions validates commit messages with the same `conventional-pre-commit` rules used by the local `commit-msg` hook.

## Running Tests

Run the Busted test suite:

```sh
make test
```

Run the Lua linter:

```sh
make lint
```

Run all pre-commit hooks manually:

```sh
make pre-commit
```

Create a guided Conventional Commit:

```sh
make commit
```

Run a Lua syntax check directly when useful:

```sh
luac -p crush-catalog.lrplugin/Info.lua
luac -p crush-catalog.lrplugin/Http.lua
luac -p crush-catalog.lrplugin/WildCatalogApi.lua
```

## Project Layout

- `crush-catalog.lrplugin/Info.lua`: Lightroom plugin metadata.
- `crush-catalog.lrplugin/Core/`: pure logic modules that should be directly unit tested.
- `crush-catalog.lrplugin/Core/WildCatalogIdentify.lua`: `/identify` request and response mapping.
- `crush-catalog.lrplugin/Core/HttpLogic.lua`: HTTP header and multipart response parsing helpers.
- `crush-catalog.lrplugin/WildCatalogApi.lua`: Lightroom/plugin-facing Wild Catalog API adapter.
- `crush-catalog.lrplugin/Http.lua`: Lightroom `LrHttp` adapter.
- `crush-catalog.lrplugin/JSON.lua`: vendored JSON library by Jeffrey Friedl.
- `tests/`: Busted specs with Lightroom APIs stubbed where needed.
- `crush-catalog-scm-1.rockspec`: LuaRocks dependency definition for local development.

## Local Wild Catalog API

The plugin expects the [Wild Catalog](https://github.com/jasondentler/wild-catalog) service at:

```text
http://localhost:8000
```

The `/identify` wrapper sends a `multipart/form-data` request with an image part and a JSON `payload` part. When `return_detected_images=true`, it requests `Accept: multipart/mixed` and expects a JSON part followed by zero or more JPEG parts.

Keep deterministic request/response rules in `Core/`. Keep Lightroom API calls, plugin loading details, dialogs, export sessions, and other host-specific behavior in top-level adapter files.

## Lightroom Notes

Lightroom plugin modules are loaded inside Lightroom's Lua runtime. When adding code:

- Prefer Lua 5.1-compatible syntax.
- Put pure logic in `Core/` and test it directly.
- Stub Lightroom APIs in adapter tests rather than requiring Lightroom to run unit tests.
- Avoid adding runtime dependencies that Lightroom cannot load from the plugin bundle.
- Keep UI/export workflow code separate from API and parsing helpers when practical.

## Third-Party Code

`JSON.lua` is vendored under a Creative Commons Attribution license. Preserve the original copyright notice, links, and `AUTHOR_NOTE` string when updating it.

If adding third-party code or assets, update `NOTICE.txt` and document the license clearly.

## Pull Request Checklist

Before opening a pull request:

- Run `make lint`.
- Run `make test`.
- Add or update Busted specs for behavior changes.
- Keep changes focused on the issue being solved.
- Update `README.md` or this file when setup, usage, or project structure changes.
- Do not commit generated dependency directories such as `.lua_modules/`.
