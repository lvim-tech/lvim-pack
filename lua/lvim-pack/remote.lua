-- lvim-pack.remote: mirror the plugins this editor runs onto a server, for Neovim's `:connect ssh://`.
--
-- remote-ssh (|remote-ssh|) copies the CONFIG to the server and leaves the plugins to the plugin manager
-- there. For third-party plugins that is exact: the lockfile travels with the config, so vim.pack installs
-- the same revisions. For `dir=` checkouts it is not — locally they are working trees (uncommitted and
-- unpushed work included), on the server they would come from GitHub, and the two editors would run
-- different code. This module closes that gap:
--
--   1. every `dir=` plugin is copied to the SAME path relative to `$HOME` on the server — which is where
--      the copied config looks for it — with rsync, source only (`.git` and whatever `.gitignore` names
--      stay home);
--   2. a built artefact (a native library, a daemon) goes along when the server can run it: same OS and
--      architecture, and no `GLIBC_x.y` symbol newer than the server's glibc. One it could not run stays
--      behind, and is named;
--   3. each copy with a build hook gets a `.lvim-pack-source` stamp (the commit it was copied from), which
--      `build.plugin_commit` reads where there is no `.git`; with a shipped artefact the build marker is
--      written too, so the server's build sweep does not try to rebuild what already works.
--
-- Every ssh connection uses the options and the ControlPath of Neovim's own remote-ssh
-- (`vim/net/_ssh.lua`), so a connection already open for `:connect` — a password typed once — is reused.
-- Every process goes through `M.run`, which the tests replace; nothing here builds a shell string from data.
--
---@module "lvim-pack.remote"

local state = require("lvim-pack.state")

local M = {}

---@type string
M.ssh = "ssh"
---@type string
M.rsync = "rsync"

--- Directories (relative to a plugin) whose files are built artefacts, shipped when the server can run
--- them. Only for plugins that declare a `build` hook.
---@type string[]
M.artefact_dirs = { "native/build" }

--- The stamp file written into each copied plugin that has a build hook.
---@type string
M.SOURCE_STAMP = ".lvim-pack-source"

---@class LvimPackRemoteTarget
---@field user string|nil
---@field host string
---@field port integer|nil

---@class LvimPackRemoteResult
---@field code integer
---@field stdout string|nil
---@field stderr string|nil

-- ---------------------------------------------------------------------------
-- Target and ssh options
-- ---------------------------------------------------------------------------

--- `ssh://[user@]host[:port][/anything]` → target. A path, if any, is ignored: the plugins go where the
--- config looks for them, not into a project.
---@param uri string
---@return LvimPackRemoteTarget|nil target
---@return string|nil err
function M.parse(uri)
    if type(uri) ~= "string" then
        return nil, "not a string"
    end
    local auth = uri:match("^ssh://([^/]+)")
    if not auth then
        return nil, "expected ssh://[user@]host[:port]"
    end
    local user, hostport = auth:match("^([^@]+)@(.+)$")
    hostport = hostport or auth
    local host, port = hostport:match("^([^:]+):(%d+)$")
    host = host or hostport
    if not host:match("^[%w][%w%.%-_]*$") then
        return nil, "invalid host"
    end
    if user and not user:match("^[%w][%w%.%-_]*$") then
        return nil, "invalid user"
    end
    local n = tonumber(port)
    if port and (not n or n < 1 or n > 65535) then
        return nil, "invalid port"
    end
    return { user = user, host = host, port = n }
end

---@param t LvimPackRemoteTarget
---@return string
local function login(t)
    return t.user and (t.user .. "@" .. t.host) or t.host
end

--- Neovim's remote-ssh ControlPath (`vim/net/_ssh.lua`): sharing it is what lets these commands ride on
--- the connection `:connect` uses.
---@return string
function M.control_path()
    return vim.fs.joinpath(vim.fn.stdpath("cache"), "ssh", "mux_%C")
end

--- The options remote-ssh runs every non-interactive ssh with: never prompt, share the master.
---@return string[]
function M.ssh_options()
    return {
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=" .. M.control_path(),
        "-o",
        "ControlPersist=10m",
        "-o",
        "RemoteCommand=none",
    }
end

--- A remote command over ssh; its input goes on stdin.
---@param t LvimPackRemoteTarget
---@param command string  a CONSTANT command line, never data
---@return string[]
function M.ssh_argv(t, command)
    local argv = vim.list_extend({ M.ssh }, M.ssh_options())
    if t.port then
        vim.list_extend(argv, { "-p", tostring(t.port) })
    end
    vim.list_extend(argv, { "--", login(t), command })
    return argv
end

--- rsync's `-e`: the same ssh, as the one string rsync takes (it splits on spaces and honours quotes).
---@param t LvimPackRemoteTarget
---@return string
function M.rsync_shell(t)
    local parts = { M.ssh }
    for _, opt in ipairs(M.ssh_options()) do
        parts[#parts + 1] = "'" .. opt:gsub("'", "") .. "'"
    end
    if t.port then
        parts[#parts + 1] = "-p " .. t.port
    end
    return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- What goes where
-- ---------------------------------------------------------------------------

---@class LvimPackRemotePlugin
---@field name string
---@field dir string     local checkout (absolute)
---@field rel string     the same path relative to $HOME — where it goes on the server
---@field build boolean  it declares a build hook

--- The `dir=` plugins and where each goes, plus the ones that cannot go (outside `$HOME`).
---@param home string|nil  local home (default: this user's)
---@return LvimPackRemotePlugin[] plugins
---@return string[] skipped  names whose checkout is outside $HOME
function M.plugins(home)
    home = vim.fs.normalize(home or vim.uv.os_homedir() or "")
    local out, skipped = {}, {}
    for name, meta in pairs(state.meta) do
        local dir = meta.spec and meta.spec.dir
        if type(dir) == "string" and dir ~= "" then
            dir = vim.fs.normalize(vim.fn.expand(dir))
            if vim.startswith(dir, home .. "/") then
                out[#out + 1] = {
                    name = name,
                    dir = dir,
                    rel = dir:sub(#home + 2),
                    build = meta.spec.build ~= nil,
                }
            else
                skipped[#skipped + 1] = name
            end
        end
    end
    table.sort(out, function(a, b)
        return a.rel < b.rel
    end)
    table.sort(skipped)
    return out, skipped
end

--- The plugins grouped by parent directory: one rsync per group.
---@param plugins LvimPackRemotePlugin[]
---@return { parent: string, rel_parent: string, names: string[] }[]
function M.groups(plugins)
    local by, order = {}, {}
    for _, p in ipairs(plugins) do
        local parent = vim.fs.dirname(p.dir)
        local g = by[parent]
        if not g then
            g = { parent = parent, rel_parent = vim.fs.dirname(p.rel), names = {} }
            by[parent] = g
            order[#order + 1] = parent
        end
        g.names[#g.names + 1] = vim.fs.basename(p.dir)
    end
    local out = {}
    for _, parent in ipairs(order) do
        out[#out + 1] = by[parent]
    end
    return out
end

--- The rsync of one group: source only. `--delete` removes what was deleted locally; files excluded here
--- (`.git`, what `.gitignore` names, the stamp) are left alone on the server, so a shipped artefact and the
--- stamp survive the next sync.
---@param t LvimPackRemoteTarget
---@param group { parent: string, rel_parent: string, names: string[] }
---@return string[]
function M.rsync_argv(t, group)
    local argv = {
        M.rsync,
        "-a",
        "--mkpath",
        "--delete",
        "--exclude=.git/",
        "--exclude=.git",
        "--exclude=" .. M.SOURCE_STAMP,
        "--filter=:- .gitignore",
        "-e",
        M.rsync_shell(t),
    }
    for _, name in ipairs(group.names) do
        argv[#argv + 1] = vim.fs.joinpath(group.parent, name)
    end
    argv[#argv + 1] = ("%s:%s/"):format(login(t), group.rel_parent)
    return argv
end

--- The rsync of the shipped artefacts: each `<parent>/./<name>/<file>`, kept relative (`-R`) so it lands
--- in the same place under the group's remote parent.
---@param t LvimPackRemoteTarget
---@param parent string
---@param rel_parent string
---@param files string[]  paths relative to `parent` (`<name>/native/build/x`)
---@return string[]
function M.artefacts_argv(t, parent, rel_parent, files)
    local argv = { M.rsync, "-aR", "--mkpath", "-e", M.rsync_shell(t) }
    for _, f in ipairs(files) do
        argv[#argv + 1] = parent .. "/./" .. f
    end
    argv[#argv + 1] = ("%s:%s/"):format(login(t), rel_parent)
    return argv
end

-- ---------------------------------------------------------------------------
-- Can the server run this binary?
-- ---------------------------------------------------------------------------

--- The newest `GLIBC_x.y` symbol version a binary asks for, as a comparable number (x * 1000 + y), or 0.
---@param path string
---@return integer
function M.glibc_needed(path)
    local fd = io.open(path, "rb")
    if not fd then
        return 0
    end
    local data = fd:read("*a") or ""
    fd:close()
    local best = 0
    for major, minor in data:gmatch("GLIBC_(%d+)%.(%d+)") do
        local v = tonumber(major) * 1000 + tonumber(minor)
        if v > best then
            best = v
        end
    end
    return best
end

--- `ldd --version`'s first line → comparable glibc version, or nil (musl, macOS, unknown).
---@param line string|nil
---@return integer|nil
function M.parse_glibc(line)
    local major, minor = (line or ""):match("GNU libc%)?%s+(%d+)%.(%d+)")
    if not major then
        major, minor = (line or ""):match("GLIBC%s+(%d+)%.(%d+)")
    end
    return major and (tonumber(major) * 1000 + tonumber(minor)) or nil
end

---@class LvimPackRemoteFacts
---@field os string|nil
---@field arch string|nil
---@field glibc integer|nil
---@field rsync boolean

--- The server probe: platform, glibc, rsync. Read-only.
---@type string
M.PROBE_SCRIPT = [[
echo "os=$(uname -s)"
echo "arch=$(uname -m)"
echo "libc=$(ldd --version 2>&1 | head -n 1)"
command -v rsync >/dev/null 2>&1 && echo "rsync=1"
f="${XDG_DATA_HOME:-$HOME/.local/share}/nvim-remote/lvim-pack/synced"
[ -r "$f" ] && echo "synced=$(head -n 1 "$f")"
exit 0
]]

--- Records what was mirrored, so the next connect can skip rsync when nothing changed. Run as `sh -s` with the
--- fingerprint AFTER the script on the same stdin (the script ends where `cat` takes the rest).
---@type string
M.SYNCED_SCRIPT = [[
lvim_pack_synced() {
  d="${XDG_DATA_HOME:-$HOME/.local/share}/nvim-remote/lvim-pack"
  mkdir -p "$d" && cat > "$d/synced"
}
lvim_pack_synced
]]

--- Bumped whenever what a mirror contains changes shape, so an older record never matches.
M.SYNC_FORMAT = 1

--- A fingerprint of everything a mirror sends: each plugin's commit, its uncommitted and untracked files
--- (path, size, mtime), and the built artefacts. Equal fingerprints here and on the server mean rsync would
--- move nothing, so it is skipped. A plugin that is not a git checkout counts by every file's size and mtime.
--- `cb(nil)` when git fails on a checkout: then nothing is skipped.
---@param plugins LvimPackRemotePlugin[]
---@param cb fun(fp: string|nil)
function M.fingerprint(plugins, cb)
    local build = require("lvim-pack.build")
    local parts, pending, failed = {}, #plugins, false
    if pending == 0 then
        return cb(vim.fn.sha256("lvim-pack-sync-" .. M.SYNC_FORMAT))
    end
    local function stat_line(path)
        local st = vim.uv.fs_stat(path)
        return st and ("%d:%d.%d"):format(st.size, st.mtime.sec, st.mtime.nsec) or "-"
    end
    local function one_done()
        pending = pending - 1
        if pending > 0 then
            return
        end
        if failed then
            return cb(nil)
        end
        table.sort(parts)
        table.insert(parts, 1, "lvim-pack-sync-" .. M.SYNC_FORMAT)
        cb(vim.fn.sha256(table.concat(parts, "\n")))
    end
    for _, p in ipairs(plugins) do
        local commit = build.plugin_commit(p.dir)
        if not commit or vim.fn.isdirectory(p.dir .. "/.git") == 0 then
            -- Not a git checkout: every file (but `.git`), by size and mtime.
            local lines = { p.rel .. " nogit" }
            for name, kind in vim.fs.dir(p.dir, { depth = 32 }) do
                if kind == "file" and not name:find("^%.git/") then
                    lines[#lines + 1] = name .. " " .. stat_line(p.dir .. "/" .. name)
                end
            end
            table.sort(lines)
            parts[#parts + 1] = table.concat(lines, "\n")
            vim.schedule(one_done)
        else
            local ok = pcall(
                vim.system,
                {
                    "git",
                    "-C",
                    p.dir,
                    "status",
                    "--porcelain=v1",
                    "-z",
                    "--untracked-files=all",
                },
                { text = true },
                vim.schedule_wrap(function(res)
                    if res.code ~= 0 then
                        failed = true
                        return one_done()
                    end
                    local lines = { p.rel .. " " .. commit }
                    for entry in (res.stdout or ""):gmatch("[^%z]+") do
                        local path = entry:sub(4)
                        lines[#lines + 1] = entry:sub(1, 2) .. " " .. path .. " " .. stat_line(p.dir .. "/" .. path)
                    end
                    if p.build then
                        for _, sub in ipairs(M.artefact_dirs) do
                            local dir = vim.fs.joinpath(p.dir, sub)
                            if vim.fn.isdirectory(dir) == 1 then
                                for file, kind in vim.fs.dir(dir) do
                                    if kind == "file" then
                                        lines[#lines + 1] = "A "
                                            .. sub
                                            .. "/"
                                            .. file
                                            .. " "
                                            .. stat_line(dir .. "/" .. file)
                                    end
                                end
                            end
                        end
                    end
                    table.sort(lines)
                    parts[#parts + 1] = table.concat(lines, "\n")
                    one_done()
                end)
            )
            if not ok then
                failed = true
                vim.schedule(one_done)
            end
        end
    end
end

---@param stdout string|nil
---@return LvimPackRemoteFacts
function M.parse_facts(stdout)
    local f = { rsync = false }
    for line in (stdout or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^(%w+)=(.*)$")
        if k == "libc" then
            f.glibc = M.parse_glibc(v)
        elseif k == "rsync" then
            f.rsync = true
        elseif k == "synced" then
            f.synced = v ~= "" and v or nil
        elseif k then
            f[k] = v
        end
    end
    return f
end

--- Whether a built file can run on the server.
---@param path string
---@param here { os: string, arch: string }
---@param there LvimPackRemoteFacts
---@return boolean
function M.runs_there(path, here, there)
    if here.os ~= there.os or here.arch ~= there.arch then
        return false
    end
    local needed = M.glibc_needed(path)
    if needed == 0 then
        return true
    end
    return there.glibc ~= nil and needed <= there.glibc
end

--- The artefacts of the build-hook plugins: which to ship, which the server could not run.
---@param plugins LvimPackRemotePlugin[]
---@param here { os: string, arch: string }
---@param there LvimPackRemoteFacts
---@return table<string, string[]> ship  parent dir → files relative to it
---@return table<string, boolean> shipped  plugin name → it has at least one shipped artefact
---@return string[] held  `name/file` that stays home
function M.artefacts(plugins, here, there)
    local ship, shipped, held = {}, {}, {}
    for _, p in ipairs(plugins) do
        if p.build then
            local parent = vim.fs.dirname(p.dir)
            local name = vim.fs.basename(p.dir)
            for _, sub in ipairs(M.artefact_dirs) do
                local dir = vim.fs.joinpath(p.dir, sub)
                if vim.fn.isdirectory(dir) == 1 then
                    for file, kind in vim.fs.dir(dir) do
                        if kind == "file" then
                            local rel = vim.fs.joinpath(name, sub, file)
                            if M.runs_there(vim.fs.joinpath(dir, file), here, there) then
                                ship[parent] = ship[parent] or {}
                                table.insert(ship[parent], rel)
                                shipped[p.name] = true
                            else
                                held[#held + 1] = rel
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(held)
    return ship, shipped, held
end

--- The stamps, as input for `STAMP_SCRIPT`: one `rel<TAB>commit<TAB>marker` line per build-hook plugin
--- with a known commit (`marker` = 1 when its artefact was shipped).
---@param plugins LvimPackRemotePlugin[]
---@param shipped table<string, boolean>
---@return string
function M.stamp_input(plugins, shipped)
    local build = require("lvim-pack.build")
    local lines = {}
    for _, p in ipairs(plugins) do
        if p.build then
            local commit = build.plugin_commit(p.dir)
            if commit then
                lines[#lines + 1] = table.concat({ p.rel, commit, shipped[p.name] and "1" or "0", p.name }, "\t")
            end
        end
    end
    return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

--- Writes each stamp, and the build marker where the artefact was shipped, into the data dir the remote
--- Neovim (`NVIM_APPNAME=nvim-remote`) uses. Run as `sh -s`, with the data lines AFTER the script on the
--- same stdin: the shell reads the loop up to `done`, and `read` then consumes exactly the lines that
--- follow (POSIX: a command run by a shell reading stdin continues right after what the shell has read).
--- So the fields arrive as data, never on the command line. The script must END with `done`.
---@type string
M.STAMP_SCRIPT = [[
data="${XDG_DATA_HOME:-$HOME/.local/share}/nvim-remote/lvim-pack/built"
tab=$(printf '\t')
while IFS="$tab" read -r rel commit marker name; do
  [ -n "$rel" ] || continue
  [ -d "$HOME/$rel" ] || continue
  printf '%s\n' "$commit" > "$HOME/$rel/.lvim-pack-source" || exit 1
  if [ "$marker" = 1 ]; then
    mkdir -p "$data" && printf '%s\n' "$commit" > "$data/$name" || exit 1
  fi
done
]]

-- ---------------------------------------------------------------------------
-- Consent
-- ---------------------------------------------------------------------------

---@return string
local function consent_file()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "lvim-pack", "remote-hosts.json")
end

---@return table<string, boolean>
local function read_consent()
    local fd = io.open(consent_file(), "r")
    if not fd then
        return {}
    end
    local raw = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, raw or "")
    return (ok and type(data) == "table") and data or {}
end

---@param key string
local function remember(key)
    local data = read_consent()
    data[key] = true
    vim.fn.mkdir(vim.fs.dirname(consent_file()), "p")
    local fd = io.open(consent_file(), "w")
    if fd then
        fd:write(vim.json.encode(data))
        fd:close()
    end
end

--- Ask a yes/no question. Tests replace it.
---@param message string
---@return boolean
function M.confirm(message)
    return vim.fn.confirm(message, "&Yes\n&No", 2) == 1
end

-- ---------------------------------------------------------------------------
-- Processes
-- ---------------------------------------------------------------------------

--- Run a command; the callback runs on the main loop. Tests replace it.
---@param argv string[]
---@param opts { stdin: string|nil, timeout: integer|nil }|nil
---@param cb fun(res: LvimPackRemoteResult)
function M.run(argv, opts, cb)
    opts = opts or {}
    local ok, err = pcall(
        vim.system,
        argv,
        { text = true, stdin = opts.stdin, timeout = opts.timeout },
        vim.schedule_wrap(function(res)
            cb({ code = res.code, stdout = res.stdout, stderr = res.stderr })
        end)
    )
    if not ok then
        vim.schedule(function()
            cb({ code = -1, stdout = "", stderr = tostring(err) })
        end)
    end
end

---@param res LvimPackRemoteResult
---@return string
local function first_line(res)
    local text = vim.trim(res.stderr or "")
    if text == "" then
        text = vim.trim(res.stdout or "")
    end
    return text:match("[^\r\n]+") or ("exit status " .. tostring(res.code))
end

--- This machine's platform, as `uname` names it.
---@return { os: string, arch: string }
function M.here()
    local u = vim.uv.os_uname()
    return { os = u.sysname, arch = u.machine }
end

-- ---------------------------------------------------------------------------
-- The sync
-- ---------------------------------------------------------------------------

---@class LvimPackRemoteReport
---@field plugins integer     how many plugins were mirrored
---@field shipped string[]    artefacts sent along
---@field held string[]       artefacts the server could not run (left home)
---@field skipped string[]    plugins outside $HOME (not mirrored)
---@field unchanged boolean|nil  nothing changed since the last mirror to this server: rsync was skipped

---@class LvimPackRemoteOpts
---@field confirm "ask"|"always"|nil  "ask" (default) asks before the FIRST sync to a host
---@field timeout integer|nil         ms for the probe and the stamp step (rsync itself is not limited)
---@field home string|nil             local home (tests)

--- Mirror the `dir=` plugins to the server. `cb(ok, err, report)` on the main loop.
---@param uri string  ssh://[user@]host[:port][/…]
---@param opts LvimPackRemoteOpts|nil
---@param cb fun(ok: boolean, err: string|nil, report: LvimPackRemoteReport|nil)
function M.sync(uri, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    local t, perr = M.parse(uri)
    if not t then
        return cb(false, "invalid target: " .. tostring(perr))
    end
    if vim.fn.executable(M.rsync) ~= 1 then
        return cb(false, "rsync is not installed here")
    end
    local plugins, skipped = M.plugins(opts.home)
    if #plugins == 0 then
        return cb(true, nil, { plugins = 0, shipped = {}, held = {}, skipped = skipped })
    end

    local key = login(t) .. ":" .. tostring(t.port or 22)
    if (opts.confirm or "ask") == "ask" and not read_consent()[key] then
        local question = ("Mirror %d local plugin checkouts to %s (rsync, source only, same paths under $HOME)?"):format(
            #plugins,
            login(t)
        )
        if not M.confirm(question) then
            return cb(false, "declined")
        end
        remember(key)
    end

    M.run(M.ssh_argv(t, "sh -s lvim-pack-probe"), { stdin = M.PROBE_SCRIPT, timeout = opts.timeout }, function(pres)
        if pres.code ~= 0 then
            return cb(false, "probe failed: " .. first_line(pres))
        end
        local there = M.parse_facts(pres.stdout)
        if not there.rsync then
            return cb(false, "rsync is not installed on the server")
        end
        M.fingerprint(plugins, function(fp)
            local groups = M.groups(plugins)
            local ship, shipped, held = M.artefacts(plugins, M.here(), there)
            local shipped_files = {}

            -- Nothing changed since the last mirror to THIS server, and the server still has it: skip rsync.
            if fp and there.synced == fp then
                return cb(true, nil, {
                    plugins = #plugins,
                    shipped = {},
                    held = held,
                    skipped = skipped,
                    unchanged = true,
                })
            end

            --- The last step: record the fingerprint on the server.
            local function record(report)
                if not fp then
                    return cb(true, nil, report)
                end
                M.run(
                    M.ssh_argv(t, "sh -s lvim-pack-synced"),
                    { stdin = M.SYNCED_SCRIPT .. fp .. "\n", timeout = opts.timeout },
                    function(res)
                        if res.code ~= 0 then
                            return cb(false, "could not record the mirror: " .. first_line(res))
                        end
                        cb(true, nil, report)
                    end
                )
            end

            local function stamps()
                local input = M.stamp_input(plugins, shipped)
                local report = { plugins = #plugins, shipped = shipped_files, held = held, skipped = skipped }
                if input == "" then
                    return record(report)
                end
                M.run(
                    M.ssh_argv(t, "sh -s lvim-pack-stamp"),
                    { stdin = M.STAMP_SCRIPT .. input, timeout = opts.timeout },
                    function(res)
                        if res.code ~= 0 then
                            return cb(false, "could not write the build stamps: " .. first_line(res))
                        end
                        record(report)
                    end
                )
            end

            local parents = vim.tbl_keys(ship)
            table.sort(parents)

            local function ship_next(i)
                if i > #parents then
                    return stamps()
                end
                local parent = parents[i]
                local rel_parent
                for _, g in ipairs(groups) do
                    if g.parent == parent then
                        rel_parent = g.rel_parent
                    end
                end
                table.sort(ship[parent])
                M.run(M.artefacts_argv(t, parent, rel_parent, ship[parent]), nil, function(res)
                    if res.code ~= 0 then
                        return cb(false, "artefact copy failed: " .. first_line(res))
                    end
                    vim.list_extend(shipped_files, ship[parent])
                    ship_next(i + 1)
                end)
            end

            local function sync_next(i)
                if i > #groups then
                    return ship_next(1)
                end
                M.run(M.rsync_argv(t, groups[i]), nil, function(res)
                    if res.code ~= 0 then
                        return cb(false, "rsync failed: " .. first_line(res))
                    end
                    sync_next(i + 1)
                end)
            end

            sync_next(1)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- The remote side: the clipboard
-- ---------------------------------------------------------------------------

--- Why this Neovim started (`v:startreason`), or nil on a Neovim that predates it. Tests replace it.
---@return string|nil
function M.start_reason()
    local ok, reason = pcall(function()
        return vim.v.startreason
    end)
    return ok and reason or nil
end

--- On the server end of `:connect ssh://`, yank and put go through OSC 52: the terminal the UI runs in
--- holds the user's clipboard, and a clipboard tool on the server (if any) would only reach the SERVER'S.
--- Neovim turns OSC 52 on by itself only when 'clipboard' is empty and it sees a terminal over ssh; a remote-ssh
--- server has no terminal, and a config with `clipboard = "unnamedplus"` rules the automatic path out anyway, so
--- yanking ended in "clipboard: No provider". A `g:clipboard` the user set is left alone.
---@param mode "osc52"|false|nil  `config.remote_clipboard`
---@return boolean set  whether it was set here
function M.setup_clipboard(mode)
    if mode == false or M.start_reason() ~= "remote-ssh" or vim.g.clipboard ~= nil then
        return false
    end
    vim.g.clipboard = mode or "osc52"
    return true
end

return M
