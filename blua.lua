-- blua.lua
-- Transpiles a BraceLua file using bracelua.lua, then executes the result.
--
-- Usage (ComputerCraft):
--   blua <file.blua> [args...]
--
-- Place bracelua.lua in the same folder as this script, or in the CWD.

local args = { ... }

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- Resolve a path relative to CWD using CC's shell, or return as-is
local function resolvePath(path)
    if shell then return shell.resolve(path) end
    return path
end

-- Read a whole file; returns content or nil, errmsg
local function readFile(path)
    if fs then
        if not fs.exists(path) then
            return nil, "File not found: " .. path
        end
        local f = fs.open(path, "r")
        if not f then return nil, "Cannot open: " .. path end
        local src = f.readAll()
        f.close()
        return src
    else
        local f, err = io.open(path, "r")
        if not f then return nil, err end
        local src = f:read("*a")
        f:close()
        return src
    end
end

-- Locate bracelua.lua.  Search order:
--   1. Same directory as THIS running script  (most reliable in CC)
--   2. Current working directory
--   3. Absolute root /bracelua.lua
local function findTranspiler()
    local candidates = {}

    if shell and fs then
        local progPath = shell.getRunningProgram() -- e.g. "mydir/blua" or "blua"
        local progDir  = fs.getDir(progPath)       -- e.g. "mydir"  or  ""

        if progDir ~= "" then
            candidates[#candidates+1] = progDir .. "/bracelua.lua"
        end
        -- CWD (shell.resolve resolves relative to the current directory)
        candidates[#candidates+1] = shell.resolve("bracelua.lua")
        -- root fallback
        candidates[#candidates+1] = "/bracelua.lua"
    else
        candidates[#candidates+1] = "bracelua.lua"
    end

    for _, path in ipairs(candidates) do
        if fs then
            if fs.exists(path) then return path end
        else
            local f = io.open(path, "r")
            if f then f:close(); return path end
        end
    end
    return nil
end

-- Load bracelua.lua as a module (returns the BraceLua table)
local function loadTranspiler(path)
    if fs then
        -- In CC, dofile runs a file and returns its return value
        local src, err = readFile(path)
        if not src then return nil, err end
        local chunk, lerr = load(src, "@bracelua.lua")
        if not chunk then return nil, lerr end
        local ok, result = pcall(chunk)
        if not ok then return nil, result end
        return result
    else
        local ok, result = pcall(dofile, path)
        if not ok then return nil, result end
        return result
    end
end

------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------

if #args < 1 then
    print("Usage: blua <file.blua> [args...]")
    return
end

local infile = resolvePath(args[1])

-- Find and load the transpiler
local transpilerPath = findTranspiler()
if not transpilerPath then
    printError("Cannot find bracelua.lua — place it in the same folder as blua.lua or in the current directory")
    return
end

local BraceLua, lerr = loadTranspiler(transpilerPath)
if not BraceLua then
    printError("Failed to load bracelua.lua: " .. tostring(lerr))
    return
end

-- Read the source file
local src, rerr = readFile(infile)
if not src then
    printError(rerr)
    return
end

-- Transpile BraceLua -> Lua
local lua, terr = BraceLua.transpile(src)
if not lua then
    printError("Transpile error: " .. tostring(terr))
    return
end

-- Compile the resulting Lua
local chunk, cerr = load(lua, "@" .. args[1])
if not chunk then
    printError("Compile error: " .. tostring(cerr))
    return
end

-- Build argument list for the sub-program (everything after the filename)
local subArgs = {}
for i = 2, #args do
    subArgs[#subArgs+1] = args[i]
end

-- Execute
local ok, err = pcall(function()
    chunk(table.unpack and table.unpack(subArgs) or unpack(subArgs))
end)

if not ok then
    printError("Runtime error: " .. tostring(err))
end