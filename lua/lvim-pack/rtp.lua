-- lvim-pack.rtp: putting a DEV plugin on the runtimepath the way `packadd` would.
--
---@module "lvim-pack.rtp"

local M = {}

--- Put a DEV plugin's directory on the runtimepath the way `packadd` would: the plugin itself
--- first, and its `after/` LAST.
---
--- `packadd` contributes two entries per plugin — `dir` and `dir/after` — and the second is the
--- whole mechanism behind `after/`: it is scanned after everything else so its ftplugin, its
--- queries and its syntax files OVERRIDE what came before. A dir plugin got only the first, so
--- anything a local checkout shipped under `after/` was silently inert (lvim-tex's treesitter
--- textobject and indent queries resolved to nothing, while the same plugin installed from git
--- worked).
---
--- Idempotent: `rtp` is a set here, and prepending a path already present just moves it.
---@param dir string
---@return nil
function M.add_dir(dir)
    vim.opt.rtp:prepend(dir)
    local after = dir .. "/after"
    if vim.fn.isdirectory(after) == 1 then
        vim.opt.rtp:append(after)
    end
end

return M
