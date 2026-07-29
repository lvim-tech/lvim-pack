# lvim-pack

The plugin **loader** for the [lvim-tech](https://github.com/lvim-tech) set, built on Neovim's own
`vim.pack`. Your config clones one small repository and calls `setup{ spec = … }`; everything after
that — fetching what the install itself needs, putting local checkouts on the runtimepath, expanding
dependencies, pinning versions, loading eagerly by priority, wiring `ft` / `cmd` / `keys` / `event`
triggers, running build hooks — happens here.

It owns **loading only**. What it installs is reported to `lvim-pkg` (the data hub) and painted by
`lvim-installer` (the progress panel), through soft hooks: both are optional, and the loader still
loads plugins on a machine where neither is present. It has no hard dependency on anything, because
it is what puts the others on the runtimepath.

## Bootstrap

The whole of it, in your `init.lua`:

```lua
local pack_dir = vim.fn.stdpath("data") .. "/site/pack/core/opt/lvim-pack"
if not vim.uv.fs_stat(pack_dir) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/lvim-tech/lvim-pack",
        pack_dir,
    })
end
vim.opt.rtp:prepend(pack_dir)

require("lvim-pack").setup({
    spec = require("modules"), -- your plugin table
})
```

## The order, and why it is the order

Every step of `load()` was learned from a failure, so the sequence is the design:

1. **Built-ins off**, spec read.
2. **Bootstrap clone** with plain `git` — not `vim.pack`. The first `vim.pack.add` of a session
   reconciles the whole lockfile: run it before the install UI exists and it clones every plugin
   behind its own aggregate progress bar, bypassing the per-plugin panel and the build phase.
3. **Local (`dir=`) checkouts onto the runtimepath** — before anything requires them, including
   those nested inside a spec's `dependencies`.
4. **Umbrella bundle → dependency resolve → version pins**, in that order, so a bundled plugin
   takes part in resolution and pinning like any other.
5. **The registry** out to the data hub.
6. **The install UI** — the first and only `vim.pack.add` of the session.
7. **Eager loads by priority**, then the lazy triggers.
8. **`UIEnter`** freezes the startup stat and fires `User VeryLazy`; the build sweep follows.

## Pinning, and who outranks whom

`vim.pack` keeps a lockfile of its own (`nvim-pack-lock.json`) and reads it as **authoritative at
install time**: a plugin listed there is checked out at the recorded revision instead of the one
inferred from its spec. That file is machine-local — vim.pack writes it itself on every install and
update — so on its own it would outrank the pin the host declared, and a `pin` would only ever take
effect through an explicit checkout afterwards.

So the loader states the intent where vim.pack looks. Before the first `vim.pack.add`, for a plugin
that is **not yet on disk**, the lock entry is dropped when the spec carries a pin — leaving that pin
as the only answer:

1. **the spec's pin** (`commit`, which is where `pin(name)` lands) — the declared intent wins
2. **the lock entry** — no pin means nothing was declared, so this machine's record decides
3. **`version` / `branch`** — the tip, when neither has an answer

An already-installed plugin is never touched: vim.pack repairs its entry from the checkout anyway,
and moving one to another revision is an update, not an install.

The same pass drops **ghost entries** — a plugin in the lockfile that is neither in the spec nor on
disk. Everything the lockfile lists gets installed, so such an entry silently resurrects a plugin
nobody declares any more; the spec decides *what* exists, the lock only answers *which revision* for
something the spec declares. An entry whose plugin is on disk stays: it may be installed on purpose
outside the spec, and nothing here uninstalls anything.

## Configuration

```lua
require("lvim-pack").setup({
    -- REQUIRED. The plugin table, or a function returning it — a function so the host can build it
    -- (merging its own layers) when the loader asks rather than when it configures.
    spec = nil,

    -- Cloned with plain `git` BEFORE the first `vim.pack.add` — see step 2 above.
    bootstrap = {
        "lvim-tech/lvim-utils",
        "lvim-tech/lvim-pkg",
        "lvim-tech/lvim-installer",
    },

    github = "https://github.com/", -- base URL a bare `owner/name` resolves against

    -- The version/commit a plugin is pinned to, by NAME. The default pins nothing; a distribution
    -- that keeps a snapshot file answers from it. A pin outranks vim.pack's lockfile — see above.
    pin = function(_name)
        return nil
    end,

    -- `vim.uv.hrtime()` taken at process start. Only the host's own init.lua can take it, so it is
    -- passed in; the loader freezes the measurement at UIEnter and serves it through `stats()`.
    start_time = nil,

    -- Built-in Vim plugins that cost startup and are not used (netrw is deliberately absent).
    disabled_builtins = {
        "loaded_gzip",
        "loaded_tarPlugin",
        "loaded_2html_plugin",
        "loaded_tutor_mode_plugin",
        "loaded_zipPlugin",
    },

    very_lazy_delay = 50, -- ms after UIEnter before `User VeryLazy` fires
    ensure_builds_delay = 1000, -- ms after startup before pending builds are swept
    build_marker = ".lvim-built", -- stamped in a plugin's dir once its build ran for that commit

    -- THE SEAMS. Each defaults to the sibling plugin when it is present and to nothing when it is
    -- not; naming one replaces exactly that piece.
    on_register = nil, -- fun(registry)  the whole static registry, once, after resolve
    on_load = nil, -- fun(name, reason, ms)  one plugin finished loading
    install_ui = nil, -- fun(specs, ctx) → boolean  drive the install; false falls back to vim.pack.add
})
```

`install_ui` receives a `ctx` with two seams:

| seam | contract |
|---|---|
| `on_visible()` | call it the moment the UI is on screen (the loader's phase window steps aside then) |
| `build_runner(name, done)` | **asynchronous** — starts that plugin's build hook and answers through `done(ok, err)`. A native build takes a minute while the call returns in milliseconds, so a UI counts a build only when `done` arrives, and must not close while one is outstanding. |

## API

```lua
require("lvim-pack").setup(opts) -- merge into the live config, then load
require("lvim-pack").load() -- load with whatever is already configured
require("lvim-pack").stats() -- { startup_ms = number|nil }
require("lvim-pack").load_plugin(name) -- load a lazy plugin NOW (deps + config + report)
require("lvim-pack.deps").resolve(modules) -- expand `dependencies` into the module graph
require("lvim-pack.deps").bundle(modules) -- expand an umbrella's own `pack.lua`
```

`stats().startup_ms` is the time from the host's `start_time` to a usable editor, frozen at
`UIEnter`. Asked before that moment it answers with the live elapsed time, so a dashboard painting
early still gets an honest number instead of nothing.

## A plugin spec

The fields a spec may carry — the lazy-style shape, read by this loader:

| field | meaning |
|---|---|
| `dir` | a local checkout: put on the runtimepath instead of being cloned |
| `dependencies` | loaded first, and installed as modules of their own |
| `priority` | eager load order, highest first (default 50) |
| `lazy` | do not load at startup; with no trigger and a config, falls back to `VeryLazy` |
| `event` / `ft` / `cmd` / `keys` | what loads it |
| `cond` | boolean or function; false installs and registers it but never loads it |
| `init` | runs BEFORE the plugin is sourced (for plugins configured through globals) |
| `config` / `opts` | run after it is on the runtimepath |
| `build` | shell string, `:ExCommand`, or a function (one parameter opts into the async contract) |
| `built` | predicate: the build's artefact is present — self-heals a build that stamped but produced nothing |
| `commit` / `version` / `branch` | what `vim.pack` checks out |

## Health

`:checkhealth lvim-pack` reports the wiring (`spec`, the seams, the startup stat), how many plugins
are registered, loaded and waiting on a trigger, and whether two copies of the loader are on the
runtimepath at once — a dev checkout and an installed clone both being live is the one failure that
looks like nothing at all.

## Installation

Through [lvim-installer](https://github.com/lvim-tech/lvim-installer), or with Neovim's native
`vim.pack` — the bootstrap snippet above is itself a `vim.pack`-managed clone, so once the set is
running the loader updates like every other plugin.

## License

BSD-3-Clause.
