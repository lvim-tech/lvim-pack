-- Mirroring the `dir=` plugins to a server (`lvim-pack.remote`).
--
-- No server is contacted. The pure parts (target parsing, which plugins go where, which built files a
-- server can run) are asserted directly. The sync itself runs END TO END with the real rsync, against a
-- fake `ssh` that runs the remote command locally with a second directory as the remote `$HOME` — so the
-- rsync filters, `--delete`, the artefact copy and the stamp script are exercised, not just named.

local remote = require("lvim-pack.remote")
local build = require("lvim-pack.build")
local state = require("lvim-pack.state")

describe("lvim-pack remote: targets and options")

it("parses ssh:// targets and ignores any path", function()
    eq({ host = "box" }, (remote.parse("ssh://box")))
    eq({ user = "me", host = "box.example", port = 1022 }, (remote.parse("ssh://me@box.example:1022/srv/x")))
    eq(nil, (remote.parse("box")))
    eq(nil, (remote.parse("ssh://box:99999")))
    eq(nil, (remote.parse("ssh://-oProxyCommand=x")))
end)

it("rsync's -e is the same ssh as Neovim's remote-ssh, quoted for rsync", function()
    local e = remote.rsync_shell({ host = "box", port = 1022 })
    truthy(e:find("'BatchMode=yes'", 1, true))
    truthy(e:find("'ControlPath=" .. remote.control_path() .. "'", 1, true), "the shared ControlPath")
    truthy(e:find("-p 1022", 1, true))
end)

it("reads glibc versions from ldd and from a binary", function()
    eq(2034, remote.parse_glibc("ldd (GNU libc) 2.34"))
    eq(2039, remote.parse_glibc("ldd (Ubuntu GLIBC 2.39-0ubuntu8) 2.39"))
    eq(nil, remote.parse_glibc("musl libc (x86_64)"))
    local f = vim.fn.tempname()
    vim.fn.writefile({ "\127ELF junk GLIBC_2.17 more GLIBC_2.34 GLIBC_2.2.5 end" }, f)
    eq(2034, remote.glibc_needed(f))
end)

it("a built file runs there only on the same platform with a glibc at least as new", function()
    local f = vim.fn.tempname()
    vim.fn.writefile({ "GLIBC_2.34" }, f)
    local here = { os = "Linux", arch = "x86_64" }
    eq(true, remote.runs_there(f, here, { os = "Linux", arch = "x86_64", glibc = 2034 }))
    eq(false, remote.runs_there(f, here, { os = "Linux", arch = "x86_64", glibc = 2031 }))
    eq(false, remote.runs_there(f, here, { os = "Linux", arch = "aarch64", glibc = 2039 }))
    eq(false, remote.runs_there(f, here, { os = "Linux", arch = "x86_64", glibc = nil }), "musl: no")
end)

it("plugins go to the same path under $HOME; a checkout outside $HOME is named, not copied", function()
    local saved = state.meta
    state.meta = {
        ["lvim-a"] = { spec = { dir = "/home/u/dev/lua/lvim-a", build = "sh x" } },
        ["lvim-b"] = { spec = { dir = "/home/u/dev/lua/lvim-b" } },
        ["other"] = { spec = { dir = "/opt/other" } },
        ["installed"] = { spec = {} },
    }
    local ok, err = pcall(function()
        local plugins, skipped = remote.plugins("/home/u")
        eq(
            { "dev/lua/lvim-a", "dev/lua/lvim-b" },
            vim.tbl_map(function(p)
                return p.rel
            end, plugins)
        )
        eq(true, plugins[1].build)
        eq({ "other" }, skipped)
        local groups = remote.groups(plugins)
        eq({ { parent = "/home/u/dev/lua", rel_parent = "dev/lua", names = { "lvim-a", "lvim-b" } } }, groups)
        local argv = remote.rsync_argv({ host = "box" }, groups[1])
        eq("box:dev/lua/", argv[#argv])
        eq({ "/home/u/dev/lua/lvim-a", "/home/u/dev/lua/lvim-b" }, { argv[#argv - 2], argv[#argv - 1] })
    end)
    state.meta = saved
    if not ok then
        error(err, 0)
    end
end)

describe("lvim-pack remote: a real rsync to a fake server")

if vim.fn.executable("rsync") ~= 1 or vim.fn.executable("git") ~= 1 then
    skip("mirrors source, ships what runs there, stamps the commit", "rsync and git are needed")
    return
end

--- Run a command, failing the test on a non-zero exit.
---@param argv string[]
---@param cwd string|nil
local function sh(argv, cwd)
    local res = vim.system(argv, { cwd = cwd, text = true }):wait()
    assert(res.code == 0, table.concat(argv, " ") .. ": " .. (res.stderr or ""))
    return res.stdout
end

--- Write `lines` to `path`, creating its directory.
local function put(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
end

it("mirrors source, ships what runs there, stamps the commit", function()
    local root = vim.fn.tempname()
    local home, far = root .. "/home", root .. "/far" -- local $HOME, the "server's" $HOME
    vim.fn.mkdir(far, "p")

    -- A plugin with a build hook: tracked source, an ignored build dir holding one binary the server can
    -- run and one it cannot, and a stray untracked file.
    local a = home .. "/dev/lua/lvim-a"
    put(a .. "/lua/a.lua", { "return 1" })
    put(a .. "/.gitignore", { "native/build/", "native/target/" })
    put(a .. "/native/build/libok.so", { "GLIBC_2.2.5" })
    put(a .. "/native/build/daemon", { "GLIBC_999.1" })
    put(a .. "/native/target/huge", { "build cache" })
    sh({ "git", "init", "-q" }, a)
    sh({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A" }, a)
    sh({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x" }, a)
    put(a .. "/lua/new.lua", { "return 2" }) -- untracked, not ignored: it is source
    local commit = vim.trim(sh({ "git", "rev-parse", "HEAD" }, a))
    -- A plugin without one.
    local b = home .. "/dev/lua/lvim-b"
    put(b .. "/lua/b.lua", { "return 3" })

    -- The fake ssh: drop the options and the destination, run the rest in the "server's" $HOME.
    local fake = root .. "/ssh"
    put(fake, {
        "#!/bin/sh",
        "while [ $# -gt 0 ]; do",
        '  case "$1" in -o|-p|-l) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac',
        "done",
        "shift",
        ('cd %q && exec env -u XDG_DATA_HOME HOME=%q sh -c "$*"'):format(far, far),
    })
    vim.uv.fs_chmod(fake, tonumber("755", 8))

    local saved = { meta = state.meta, ssh = remote.ssh }
    state.meta = {
        ["lvim-a"] = { spec = { dir = a, build = "sh native/build.sh" } },
        ["lvim-b"] = { spec = { dir = b } },
    }
    remote.ssh = fake
    local function sync()
        local result
        remote.sync("ssh://box", { confirm = "always", home = home }, function(ok, err, report)
            result = { ok = ok, err = err, report = report }
        end)
        vim.wait(20000, function()
            return result ~= nil
        end, 20)
        return result
    end

    local ok, err = pcall(function()
        local r = sync()
        eq(true, r.ok, tostring(r.err))
        local fa = far .. "/dev/lua/lvim-a"
        eq(1, vim.fn.filereadable(fa .. "/lua/a.lua"), "tracked source")
        eq(1, vim.fn.filereadable(fa .. "/lua/new.lua"), "untracked source")
        eq(1, vim.fn.filereadable(far .. "/dev/lua/lvim-b/lua/b.lua"), "the second plugin")
        eq(0, vim.fn.isdirectory(fa .. "/.git"), "no .git")
        eq(0, vim.fn.isdirectory(fa .. "/native/target"), "no build cache")
        eq(1, vim.fn.filereadable(fa .. "/native/build/libok.so"), "a binary the server can run")
        eq(0, vim.fn.filereadable(fa .. "/native/build/daemon"), "not one it cannot")
        eq({ "lvim-a/native/build/daemon" }, r.report.held)
        eq({ "lvim-a/native/build/libok.so" }, r.report.shipped)
        eq({ commit }, vim.fn.readfile(fa .. "/.lvim-pack-source"), "the stamp")
        eq(commit, build.plugin_commit(fa), "which the build sweep reads where there is no .git")
        eq({ commit }, vim.fn.readfile(far .. "/.local/share/nvim-remote/lvim-pack/built/lvim-a"), "the marker")
        eq(0, vim.fn.filereadable(far .. "/dev/lua/lvim-b/.lvim-pack-source"), "no build hook, no stamp")

        -- Delete a file locally and sync again: it goes; the shipped binary and the stamp stay.
        vim.fn.delete(a .. "/lua/new.lua")
        r = sync()
        eq(true, r.ok, tostring(r.err))
        eq(0, vim.fn.filereadable(fa .. "/lua/new.lua"), "deleted here, deleted there")
        eq(1, vim.fn.filereadable(fa .. "/native/build/libok.so"), "the shipped binary survives")
        eq({ commit }, vim.fn.readfile(fa .. "/.lvim-pack-source"), "and so does the stamp")

        -- Nothing changed: the mirror is skipped. Mark the copy to prove rsync did not run.
        vim.fn.writefile({ "server-only" }, fa .. "/lua/marker.lua")
        r = sync()
        eq(true, r.ok, tostring(r.err))
        eq(true, r.report.unchanged, "unchanged since the last mirror")
        eq(1, vim.fn.filereadable(fa .. "/lua/marker.lua"), "rsync --delete did not run")

        -- An already modified file changes again: same git status, new content. It is mirrored.
        put(a .. "/lua/a.lua", { "return 'edited'" })
        r = sync()
        eq(nil, r.report.unchanged)
        eq({ "return 'edited'" }, vim.fn.readfile(fa .. "/lua/a.lua"))
        put(a .. "/lua/a.lua", { "return 'edited again'" })
        r = sync()
        eq(nil, r.report.unchanged, "a second edit of a dirty file is a change too")
        eq({ "return 'edited again'" }, vim.fn.readfile(fa .. "/lua/a.lua"))

        -- The server lost its record (wiped, reinstalled): mirrored again.
        vim.fn.delete(far .. "/.local/share/nvim-remote/lvim-pack/synced")
        r = sync()
        eq(nil, r.report.unchanged)
        eq(1, vim.fn.filereadable(far .. "/.local/share/nvim-remote/lvim-pack/synced"))
    end)
    state.meta, remote.ssh = saved.meta, saved.ssh
    vim.fn.delete(root, "rf")
    if not ok then
        error(err, 0)
    end
end)

describe("lvim-pack build: reading a plugin's commit")

it("a packed ref, a stamp-only copy, and a directory with neither", function()
    if vim.fn.executable("git") ~= 1 then
        return skip("a packed ref, a stamp-only copy, and a directory with neither", "git is needed")
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "x" }, dir .. "/f")
    local function git(...)
        local res = vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t" }, { ... }), {
            cwd = dir,
            text = true,
        }):wait()
        assert(res.code == 0, res.stderr)
        return vim.trim(res.stdout or "")
    end
    git("init", "-q")
    git("add", "-A")
    git("commit", "-qm", "x")
    local head = git("rev-parse", "HEAD")
    git("pack-refs", "--all")
    eq(head, build.plugin_commit(dir), "the ref lives only in packed-refs")

    local copy = vim.fn.tempname()
    vim.fn.mkdir(copy, "p")
    eq(nil, build.plugin_commit(copy), "no .git, no stamp: nil, not an error")
    vim.fn.writefile({ head }, copy .. "/.lvim-pack-source")
    eq(head, build.plugin_commit(copy))
    vim.fn.writefile({ "not a sha" }, copy .. "/.lvim-pack-source")
    eq(nil, build.plugin_commit(copy), "a stamp that is not a commit is ignored")
end)

describe("lvim-pack build: a build that cannot succeed is not retried on every start")

it("reads the missing tool from a shell's exit status 127", function()
    eq("cargo", build.missing_tool(127, "native/build.sh: line 17: cargo: command not found\n"))
    eq("cargo", build.missing_tool(127, "native/build.sh: 17: cargo: not found\n"), "dash words it so")
    eq(nil, build.missing_tool(1, "cargo: command not found"), "only 127 means a missing command")
    eq(nil, build.missing_tool(101, "error: could not compile"))
end)

it("a missing tool blocks the sweep at that commit only, and only while the tool is missing", function()
    local name = "lvim-test-missing-" .. vim.uv.hrtime()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local commit = ("ab"):rep(20)
    vim.fn.writefile({ commit }, dir .. "/.lvim-pack-source")
    local done
    build.run(name, "exit 127 # sh: lvim-no-such-tool: command not found", dir, function(ok)
        done = ok
    end)
    -- `exit 127` prints nothing; the message is what the shell would say. Use a real missing command.
    vim.wait(5000, function()
        return done ~= nil
    end, 10)
    eq(false, done)
    eq(false, build.blocked(name, commit), "no tool named: nothing remembered")

    done = nil
    build.run(name, "lvim-no-such-tool-xyz --version", dir, function(ok)
        done = ok
    end)
    vim.wait(5000, function()
        return done ~= nil
    end, 10)
    eq(false, done)
    eq(true, build.blocked(name, commit), "the same commit, the tool still missing: skip")
    eq(false, build.blocked(name, ("cd"):rep(20)), "another commit: try again")
    local file = vim.fn.stdpath("data") .. "/lvim-pack/built/" .. name .. ".missing"
    vim.fn.writefile({ commit .. "\tsh" }, file)
    eq(false, build.blocked(name, commit), "the tool is on PATH now: try again")

    done = nil
    build.run(name, "true", dir, function(ok)
        done = ok
    end)
    vim.wait(5000, function()
        return done ~= nil
    end, 10)
    eq(true, done)
    eq(0, vim.fn.filereadable(file), "a success forgets the missing tool")
end)

describe("lvim-pack build: where the compile cache goes")

local config = require("lvim-pack.config")

it("cache by default, tmp, a path, or left to the build", function()
    local saved, env = config.build_cache, vim.env.CARGO_TARGET_DIR
    vim.env.CARGO_TARGET_DIR = nil
    local ok, err = pcall(function()
        config.build_cache = nil
        eq(vim.fs.joinpath(vim.fn.stdpath("cache"), "lvim-pack", "build", "p"), build.target_dir("p"), "the default")
        config.build_cache = "cache"
        eq(vim.fs.joinpath(vim.fn.stdpath("cache"), "lvim-pack", "build", "p"), build.target_dir("p"))
        config.build_cache = "tmp"
        eq(vim.fs.joinpath(vim.env.TMPDIR or "/tmp", "lvim-pack-build", "p"), build.target_dir("p"))
        config.build_cache = "/data/cargo"
        eq("/data/cargo/p", build.target_dir("p"))
        config.build_cache = "plugin"
        eq(nil, build.target_dir("p"))
        config.build_cache = "cache"
        vim.env.CARGO_TARGET_DIR = "/mine"
        eq(nil, build.target_dir("p"), "the user's own CARGO_TARGET_DIR wins")
    end)
    config.build_cache, vim.env.CARGO_TARGET_DIR = saved, env
    if not ok then
        error(err, 0)
    end
end)

it("a shell build sees it as CARGO_TARGET_DIR", function()
    local saved, env = config.build_cache, vim.env.CARGO_TARGET_DIR
    vim.env.CARGO_TARGET_DIR = nil
    config.build_cache = "/data/cargo"
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local done
    build.run("lvim-test-target-" .. vim.uv.hrtime(), 'printf %s "$CARGO_TARGET_DIR" > seen', dir, function(ok)
        done = ok
    end)
    vim.wait(5000, function()
        return done ~= nil
    end, 10)
    config.build_cache, vim.env.CARGO_TARGET_DIR = saved, env
    eq(true, done)
    truthy(vim.startswith(vim.fn.readfile(dir .. "/seen")[1] or "", "/data/cargo/lvim-test-target-"))
end)

describe("lvim-pack remote: the clipboard on the server end")

it("OSC 52 on a remote-ssh start, unless the user chose a clipboard or turned it off", function()
    local saved_reason, saved_clip = remote.start_reason, vim.g.clipboard
    local ok, err = pcall(function()
        remote.start_reason = function()
            return "remote-ssh"
        end
        vim.g.clipboard = nil
        eq(true, remote.setup_clipboard("osc52"))
        eq("osc52", vim.g.clipboard)

        vim.g.clipboard = { name = "mine" }
        eq(false, remote.setup_clipboard("osc52"), "the user's own g:clipboard stays")
        eq("mine", vim.g.clipboard.name)

        vim.g.clipboard = nil
        eq(false, remote.setup_clipboard(false), "turned off")
        eq(nil, vim.g.clipboard)

        remote.start_reason = function()
            return "normal"
        end
        eq(false, remote.setup_clipboard("osc52"), "a local start keeps its clipboard tool")
        eq(nil, vim.g.clipboard)
    end)
    remote.start_reason, vim.g.clipboard = saved_reason, saved_clip
    if not ok then
        error(err, 0)
    end
end)
