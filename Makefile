.PHONY: commit commit-deps hooks pre-commit test test-deps

LUA_DIR ?= /opt/homebrew/opt/luajit
LUA_VERSION ?= 5.1
LUAROCKS ?= luarocks --lua-version=$(LUA_VERSION) --lua-dir=$(LUA_DIR)
UV ?= uv
UV_CACHE_DIR ?= .uv-cache
PRE_COMMIT_HOME ?= .pre-commit-cache

test-deps:
	$(LUAROCKS) make --tree .lua_modules --only-deps crush-catalog-scm-1.rockspec

test:
	.lua_modules/bin/busted tests

commit-deps:
	UV_CACHE_DIR=$(UV_CACHE_DIR) $(UV) sync --group dev

hooks: commit-deps
	UV_CACHE_DIR=$(UV_CACHE_DIR) PRE_COMMIT_HOME=$(PRE_COMMIT_HOME) $(UV) run pre-commit install --install-hooks
	UV_CACHE_DIR=$(UV_CACHE_DIR) PRE_COMMIT_HOME=$(PRE_COMMIT_HOME) $(UV) run pre-commit install --hook-type commit-msg

pre-commit:
	UV_CACHE_DIR=$(UV_CACHE_DIR) PRE_COMMIT_HOME=$(PRE_COMMIT_HOME) $(UV) run pre-commit run --all-files

commit:
	UV_CACHE_DIR=$(UV_CACHE_DIR) $(UV) run cz commit
