-- lvim-pack.config: the LIVE configuration. `setup()` merges the user's options into this table in
-- place, and every module reads `require("lvim-pack.config")` — so what is read is always what is
-- in effect, with no second copy to drift.
--
-- The loader is DISTRIBUTION-AGNOSTIC: everything it cannot know about the host — where the specs
-- come from, how a version is pinned, who records the loads, who paints the install — is a hook
-- here with a working default. A config that supplies only `spec` gets the whole lvim-tech
-- experience; one that supplies more replaces exactly the piece it names.
--
---@module "lvim-pack.config"

---@class LvimPackConfig
---@field spec (fun():table)|table|nil  the plugin table, or a function returning it (REQUIRED —
---   the loader has nothing to load without it)
---@field bootstrap string[]  repos cloned with plain `git` BEFORE the first `vim.pack.add`
---@field github string  base URL a bare `owner/name` is resolved against
---@field pin fun(name: string):(string|nil)  the version/commit a plugin is pinned to, by NAME
---@field start_time integer|nil  `vim.uv.hrtime()` taken at process start, for `stats()`
---@field disabled_builtins string[]  load-guard globals set to 1 before anything loads
---@field very_lazy_delay integer  ms after UIEnter before the VeryLazy event fires
---@field ensure_builds_delay integer  ms after startup before pending builds are swept
---@field build_marker string  file stamped in a plugin's dir once its build ran for that commit
---@field on_register (fun(registry: table))|nil  the whole static registry, once, after resolve
---@field on_load (fun(name: string, reason: string, ms: number))|nil  one plugin finished loading
---@field install_ui (fun(specs: table[], ctx: table):boolean)|nil  drive the install; return false
---   to fall back to a plain `vim.pack.add`. `ctx` carries `on_visible()` (call it once the UI is
---   on screen) and `build_runner(name, done)` — an ASYNC contract: it starts the plugin's build
---   hook and reports through `done(ok, err)`, so a UI must wait for that call, never for the
---   return, before it counts the build as finished

---@type LvimPackConfig
local M = {
    -- THE ONE REQUIRED OPTION. A table, or a function returning one — a function so the host can
    -- build it lazily (merging its base and user layers) at the moment the loader asks, not at
    -- the moment it configures.
    spec = nil,

    -- CLONED WITH PLAIN `git`, NOT through vim.pack. The first `vim.pack.add` reconciles the WHOLE
    -- lockfile: run it before these exist and it clones every plugin behind vim.pack's own
    -- aggregate progress bar, bypassing the installer's per-plugin panel and the build phase. So
    -- the few plugins the install itself needs are fetched directly first, and the first
    -- `vim.pack.add` stays where it belongs — inside the installer.
    bootstrap = {
        "lvim-tech/lvim-utils",
        "lvim-tech/lvim-pkg",
        "lvim-tech/lvim-installer",
    },

    github = "https://github.com/",

    -- The pin for a plugin, by name. The default pins nothing — a distribution that keeps a
    -- snapshot file answers from it.
    ---@param _name string
    ---@return string|nil
    pin = function(_name)
        return nil
    end,

    -- Process start, for the startup stat. Only the host's own `init.lua` can take it (this
    -- plugin is not loaded yet at that moment), so it is passed in rather than measured here.
    start_time = nil,

    -- Built-in Vim plugins that cost startup and are not used. netrw is deliberately absent — it
    -- is used.
    disabled_builtins = {
        "loaded_gzip",
        "loaded_tarPlugin",
        "loaded_2html_plugin",
        "loaded_tutor_mode_plugin",
        "loaded_zipPlugin",
    },

    very_lazy_delay = 50,
    ensure_builds_delay = 1000,
    build_marker = ".lvim-built",

    -- The DATA HUB. Defaults report to lvim-pkg when it is there and do nothing when it is not:
    -- the loader must load plugins on a machine where the introspection plugin is absent.
    on_register = nil,
    on_load = nil,

    -- THE INSTALL UI. The default hands the specs to lvim-installer's bootstrap panel; without it
    -- the loader falls back to a plain `vim.pack.add`, which installs correctly and silently.
    install_ui = nil,
}

return M
