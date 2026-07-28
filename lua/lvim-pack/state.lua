-- lvim-pack.state: what the loader knows WHILE it runs — never configuration.
--
-- Two tables and one number, shared by the modules that would otherwise have to pass them to each
-- other: the dedupe guard (a plugin loads once, whoever asks), the per-plugin meta the triggers and
-- the build sweep read back, and the startup stat frozen at UIEnter.
--
---@module "lvim-pack.state"

---@class LvimPackMeta
---@field repo string   `owner/name` as declared
---@field spec table    the plugin's own spec table
---@field lazy boolean  it is NOT loaded eagerly (a trigger, `lazy = true`, or `cond` false)

local M = {}

---@type table<string, boolean>  plugins already loaded — the dedupe guard
M.loaded = {}

---@type table<string, LvimPackMeta>  name → meta
M.meta = {}

---@type number|nil  ms from the host's `start_time` to UIEnter, i.e. time to a usable editor
M.startup_ms = nil

return M
