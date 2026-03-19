-- make.lua
-- BraceLua build system. Searches the current directory and parents
-- for a file called `bmake`, loads it as the build config, then
-- compiles .blua sources listed in it.
--
-- Usage:
--   make              -- build "default" target
--   make <target>     -- build a named target  (group of files)
--   make <file>       -- build a single named file
--   make clean        -- delete all build outputs

------------------------------------------------------------------------
-- Find bmake config
------------------------------------------------------------------------

local function findBmake()
  local dir = shell.dir()
  while true do
    local candidate = (dir == "" and "bmake" or dir .. "/bmake")
    if fs.exists(candidate) and not fs.isDir(candidate) then
      return candidate, dir
    end
    if dir == "" then break end
    dir = fs.getDir(dir)
  end
  return nil
end

local bmakePath, projectRoot = findBmake()
if not bmakePath then
  printError("No 'bmake' file found in " .. shell.dir() .. " or any parent directory.")
  return
end

print("Using: " .. bmakePath)

local f = fs.open(bmakePath, "r")
local code = f.readAll()
f.close()

local chunk, err = load(code, "@bmake")
if not chunk then
  printError("Error parsing bmake: " .. err)
  return
end

local ok, config = pcall(chunk)
if not ok or type(config) ~= "table" then
  printError("bmake must return a table. Got: " .. tostring(config))
  return
end

local files    = config.files   or {}
local targets  = config.targets or {}
local BRACELUA = config.bracelua or "bracelua.lua"
BRACELUA = (projectRoot == "" and BRACELUA or projectRoot .. "/" .. BRACELUA)

------------------------------------------------------------------------
-- Cache
------------------------------------------------------------------------

local CACHE_FILE = (projectRoot == "" and ".build_cache" or projectRoot .. "/.build_cache")

local function loadCache()
  local cache = {}
  if fs.exists(CACHE_FILE) then
    local cf = fs.open(CACHE_FILE, "r")
    local line = cf.readLine()
    while line do
      local k, v = line:match("^(.-)=(.+)$")
      if k then cache[k] = tonumber(v) end
      line = cf.readLine()
    end
    cf.close()
  end
  return cache
end

local function saveCache(cache)
  local cf = fs.open(CACHE_FILE, "w")
  for k, v in pairs(cache) do
    cf.writeLine(k .. "=" .. tostring(v))
  end
  cf.close()
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function hashFile(path)
  if not fs.exists(path) then return 0 end
  local hf = fs.open(path, "r")
  local content = hf.readAll()
  hf.close()
  local h = 0
  for i = 1, #content do
    h = (h * 31 + content:byte(i)) % 2147483647
  end
  return h
end

local function ensureDir(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function resolve(path)
  if projectRoot == "" then return shell.resolve(path) end
  return shell.resolve(projectRoot .. "/" .. path)
end

local function loadTranspiler()
  local resolved = shell.resolve(BRACELUA)
  if not fs.exists(resolved) then
    error("Cannot find bracelua.lua at: " .. resolved, 2)
  end
  local tf = fs.open(resolved, "r")
  local tcode = tf.readAll()
  tf.close()
  local tchunk, terr = load(tcode, "@bracelua.lua")
  if not tchunk then error("Failed to load bracelua.lua: " .. terr, 2) end
  local tok, BraceLua = pcall(tchunk)
  if not tok then error("Error in bracelua.lua: " .. tostring(BraceLua), 2) end
  return BraceLua
end

------------------------------------------------------------------------
-- Build a single file entry { src=..., out=... }
------------------------------------------------------------------------

local function buildFile(BraceLua, cache, entry, label)
  local srcPath = resolve(entry.src)
  local outPath = resolve(entry.out)
  label = label or entry.src

  if not fs.exists(srcPath) then
    printError("  [MISSING] " .. label .. " (" .. srcPath .. ")")
    return false
  end

  local currentHash = hashFile(srcPath)
  if cache[srcPath] == currentHash and fs.exists(outPath) then
    print("  [skip]  " .. label .. "  (unchanged)")
    return true
  end

  local sf = fs.open(srcPath, "r")
  local src = sf.readAll()
  sf.close()

  local lua, berr = BraceLua.transpile(src)
  if not lua then
    printError("  [ERROR] " .. label .. ": " .. tostring(berr))
    return false
  end

  ensureDir(outPath)
  local of = fs.open(outPath, "w")
  of.write(lua)
  of.close()

  cache[srcPath] = currentHash
  print("  [built] " .. label .. " -> " .. entry.out)
  return true
end

------------------------------------------------------------------------
-- Resolve a command to a list of { label, entry } pairs
------------------------------------------------------------------------

local function resolveCmd(cmd)
  -- Is it a named single file?
  if files[cmd] then
    return { { label = cmd, entry = files[cmd] } }
  end

  -- Is it a named target?
  if targets[cmd] then
    local list = targets[cmd]

    -- Special __all__ target
    if list[1] == "__all__" then
      local all = {}
      for name, _ in pairs(targets) do
        if name ~= "all" then
          for _, item in ipairs(resolveCmd(name)) do
            all[#all+1] = item
          end
        end
      end
      return all
    end

    -- Target is a list of file names or inline { src, out } tables
    local result = {}
    for _, item in ipairs(list) do
      if type(item) == "string" then
        -- Named file reference
        if files[item] then
          result[#result+1] = { label = item, entry = files[item] }
        else
          printError("  [warn] target '" .. cmd .. "' references unknown file '" .. item .. "'")
        end
      elseif type(item) == "table" then
        -- Inline { src, out } entry
        result[#result+1] = { label = item.src, entry = item }
      end
    end
    return result
  end

  return nil
end

------------------------------------------------------------------------
-- Clean
------------------------------------------------------------------------

local function cleanAll()
  for name, entry in pairs(files) do
    local outPath = resolve(entry.out)
    if fs.exists(outPath) then
      fs.delete(outPath)
      print("  [deleted] " .. name .. " (" .. entry.out .. ")")
    end
  end
  if fs.exists(CACHE_FILE) then
    fs.delete(CACHE_FILE)
    print("  [deleted] .build_cache")
  end
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

local args = { ... }
local cmd  = args[1] or "default"

if cmd == "clean" then
  print("Cleaning...")
  cleanAll()
  print("Done.")
  return
end

-- List available files and targets
if cmd == "list" then
  print("Files:")
  for name, entry in pairs(files) do
    print("  " .. name .. "  (" .. entry.src .. " -> " .. entry.out .. ")")
  end
  print("Targets:")
  for name, list in pairs(targets) do
    if list[1] == "__all__" then
      print("  " .. name .. "  (all targets)")
    else
      print("  " .. name .. "  (" .. #list .. " files)")
    end
  end
  return
end

local items = resolveCmd(cmd)
if not items then
  printError("Unknown file or target: '" .. cmd .. "'  (run `make list` to see options)")
  return
end

print("Building: " .. cmd .. " (" .. #items .. " file(s))")

local tok, BraceLua = pcall(loadTranspiler)
if not tok then
  printError(tostring(BraceLua))
  return
end

local cache   = loadCache()
local allOk   = true
for _, item in ipairs(items) do
  if not buildFile(BraceLua, cache, item.entry, item.label) then
    allOk = false
  end
end
saveCache(cache)

if allOk then
  print("Done.")
  if config.onSuccess then config.onSuccess() end
else
  printError("Build finished with errors.")
end