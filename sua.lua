-- sua.lua
-- BraceLua transpiler v2 -- clean architecture
--
-- Key design principles:
--   1. Single tokenizer pass that attaches line numbers to every token
--   2. Pre-passes are token->token transforms, never text->text
--   3. One shared scope analysis pass; checkers consume the result
--   4. Checkers walk tokens + scope, never pattern-match text
--   5. Source map survives all transforms (original line on every token)
--   6. Pipeline is a flat list of named stages -- easy to extend
--   7. Functions are short and single-purpose; nesting kept shallow
--
-- Usage (CC / standard Lua):
--   local BL = require("sua")  -- or dofile / loadfile
--   local result = Sua.transpile(source, options)
--   local warns  = Sua.check(source, { tc=true, rc=true, dc=true })
--
-- CLI:
--   sua [flags] <input.sua> [output.lua]
--   Flags:
--     --tc / --type-check
--     --rc / --return-check
--     --dc / --declaration-check
--     --debug=name1,name2
--     --debug-all

local Sua = {}

------------------------------------------------------------------------
-- TOKEN KINDS
------------------------------------------------------------------------

local K = {
  -- Literals
  NUMBER   = "NUMBER",
  STRING   = "STRING",
  NAME     = "NAME",       -- identifiers
  -- Keywords (subset that drives transpile logic)
  KW       = "KW",
  -- Punctuation
  LBRACE   = "LBRACE",     -- {
  RBRACE   = "RBRACE",     -- }
  LPAREN   = "LPAREN",     -- (
  RPAREN   = "RPAREN",     -- )
  LBRACKET = "LBRACKET",   -- [
  RBRACKET = "RBRACKET",   -- ]
  COMMA    = "COMMA",
  SEMI     = "SEMI",
  DOT      = "DOT",
  DOTDOT   = "DOTDOT",
  DOTDOTDOT= "DOTDOTDOT",
  COLON    = "COLON",
  DCOLON   = "DCOLON",
  OP       = "OP",         -- all other operators
  -- Whitespace / structural
  NEWLINE  = "NEWLINE",
  SPACE    = "SPACE",
  COMMENT  = "COMMENT",
  -- Synthetic tokens inserted by pre-passes
  RAW      = "RAW",        -- raw Lua passthrough
  EOF      = "EOF",
}
Sua.K = K

-- Lua keywords that must not be emitted as identifiers
local LUA_KEYWORDS = {
  ["and"]=true,["break"]=true,["do"]=true,["else"]=true,
  ["elseif"]=true,["end"]=true,["false"]=true,["for"]=true,
  ["function"]=true,["goto"]=true,["if"]=true,["in"]=true,
  ["local"]=true,["nil"]=true,["not"]=true,["or"]=true,
  ["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
  ["until"]=true,["while"]=true,
}

-- BraceLua-only keywords (not valid in output Lua)
local BL_KEYWORDS = {
  ["let"]=true, ["glet"]=true, ["global"]=true,
  ["struct"]=true, ["enum"]=true, ["switch"]=true,
  ["case"]=true, ["default"]=true, ["define"]=true,
}

------------------------------------------------------------------------
-- TOKEN CONSTRUCTOR
------------------------------------------------------------------------

local function tok(kind, value, line)
  return { k=kind, v=value, line=line }
end

------------------------------------------------------------------------
-- TOKENIZER
-- Returns a flat array of token objects, each with .k .v .line
-- Never fails -- unknown chars become OP tokens.
------------------------------------------------------------------------

local function tokenize(src)
  local tokens = {}
  local i      = 1
  local line   = 1
  local len    = #src

  local function push(k, v, l) tokens[#tokens+1] = tok(k, v, l or line) end
  local function cur() return src:sub(i,i) end
  local function peek(n) return src:sub(i, i+(n or 1)-1) end
  local function adv(n) i = i + (n or 1) end

  while i <= len do
    local c = cur()

    -- Newline
    if c == "\n" then
      push(K.NEWLINE, "\n"); line = line + 1; adv()

    -- Spaces / tabs
    elseif c == " " or c == "\t" or c == "\r" then
      local s = i
      while i <= len and (cur()==" " or cur()=="\t" or cur()=="\r") do adv() end
      push(K.SPACE, src:sub(s, i-1))

    -- Long string / long comment  [=*[
    elseif c == "[" and (src:sub(i+1,i+1)=="[" or src:sub(i+1,i+1)=="=") then
      local eq = 0
      local j  = i + 1
      while j <= len and src:sub(j,j) == "=" do eq=eq+1; j=j+1 end
      if src:sub(j,j) == "[" then
        local close = "]" .. string.rep("=",eq) .. "]"
        local s    = i
        local sl   = line
        local e    = src:find(close, j+1, true)
        if e then
          local body = src:sub(s, e + #close - 1)
          for _ in body:gmatch("\n") do line=line+1 end
          push(K.STRING, body, sl); i = e + #close
        else
          push(K.STRING, src:sub(s), sl); i = len+1
        end
      else
        push(K.LBRACKET, "["); adv()
      end

    -- Short string
    elseif c == '"' or c == "'" then
      local q  = c
      local s  = i
      local sl = line
      adv()
      while i <= len do
        local ch = cur()
        if ch == "\\" then adv(2)
        elseif ch == q then adv(); break
        elseif ch == "\n" then line=line+1; adv()
        else adv() end
      end
      push(K.STRING, src:sub(s, i-1), sl)

    -- Comment  --  or  --[[
    elseif peek(2) == "--" then
      local sl = line
      adv(2)
      if peek(2) == "[[" or (cur()=="[" and src:sub(i+1,i+1)=="=") then
        -- long comment -- reuse long-string logic by backing up
        -- just scan for ]] manually
        local eq = 0
        local j = i+1
        while j<=len and src:sub(j,j)=="=" do eq=eq+1; j=j+1 end
        if src:sub(j,j)=="[" then
          local close = "]" .. string.rep("=",eq) .. "]"
          local e = src:find(close, j+1, true)
          local body
          if e then body=src:sub(i-2, e+#close-1); i=e+#close
          else   body=src:sub(i-2); i=len+1 end
          for _ in body:gmatch("\n") do line=line+1 end
          push(K.COMMENT, body, sl)
        else
          local e = src:find("\n", i) or len
          push(K.COMMENT, src:sub(i-2, e-1), sl); i=e
        end
      else
        local e = src:find("\n", i) or len+1
        push(K.COMMENT, src:sub(i-2, e-1), sl); i=e
      end

    -- Numbers
    elseif c:match("%d") or (c=="." and src:sub(i+1,i+1):match("%d")) then
      local s = i
      if peek(2)=="0x" or peek(2)=="0X" then
        adv(2)
        while i<=len and cur():match("[%x_]") do adv() end
      else
        while i<=len and cur():match("[%d_]") do adv() end
        if i<=len and cur()=="." then
          adv()
          while i<=len and cur():match("%d") do adv() end
        end
        if i<=len and cur():match("[eE]") then
          adv()
          if i<=len and cur():match("[%+%-]") then adv() end
          while i<=len and cur():match("%d") do adv() end
        end
      end
      push(K.NUMBER, src:sub(s, i-1))

    -- Identifiers and keywords
    elseif c:match("[%a_]") then
      local s = i
      while i<=len and cur():match("[%w_]") do adv() end
      local w = src:sub(s, i-1)
      if LUA_KEYWORDS[w] or BL_KEYWORDS[w] then push(K.KW, w)
      else push(K.NAME, w) end

    -- Multi-char operators and punctuation
    elseif peek(3) == "..." then push(K.DOTDOTDOT, "..."); adv(3)
    elseif peek(3) == "..=" then push(K.OP, "..="); adv(3)
    elseif peek(2) == ".."  then push(K.DOTDOT, ".."); adv(2)
    elseif peek(2) == "::"  then push(K.DCOLON, "::"); adv(2)
    elseif peek(2) == "->"  then push(K.OP, "->"); adv(2)
    elseif peek(2) == "++"  then push(K.OP, "++"); adv(2)
    elseif peek(2) == "--"  then push(K.OP, "--"); adv(2)  -- dec (comment handled above)
    elseif peek(2) == "+="  then push(K.OP, "+="); adv(2)
    elseif peek(2) == "-="  then push(K.OP, "-="); adv(2)
    elseif peek(2) == "*="  then push(K.OP, "*="); adv(2)
    elseif peek(2) == "/="  then push(K.OP, "/="); adv(2)
    elseif peek(3) == "//=" then push(K.OP, "//="); adv(3)
    elseif peek(2) == "%="  then push(K.OP, "%="); adv(2)
    elseif peek(2) == "^="  then push(K.OP, "^="); adv(2)
    elseif peek(2) == "=="  then push(K.OP, "=="); adv(2)
    elseif peek(2) == "~="  then push(K.OP, "~="); adv(2)
    elseif peek(2) == "!="  then push(K.OP, "!="); adv(2)  -- normalised later
    elseif peek(2) == "<="  then push(K.OP, "<="); adv(2)
    elseif peek(2) == ">="  then push(K.OP, ">="); adv(2)
    elseif peek(2) == "//"  then push(K.OP, "//"); adv(2)
    elseif c == "{"  then push(K.LBRACE,   "{"); adv()
    elseif c == "}"  then push(K.RBRACE,   "}"); adv()
    elseif c == "("  then push(K.LPAREN,   "("); adv()
    elseif c == ")"  then push(K.RPAREN,   ")"); adv()
    elseif c == "["  then push(K.LBRACKET, "["); adv()
    elseif c == "]"  then push(K.RBRACKET, "]"); adv()
    elseif c == ","  then push(K.COMMA,    ","); adv()
    elseif c == ";"  then push(K.SEMI,     ";"); adv()
    elseif c == "."  then push(K.DOT,      "."); adv()
    elseif c == ":"  then push(K.COLON,    ":"); adv()
    else push(K.OP, c); adv()
    end
  end

  push(K.EOF, "", line)
  return tokens
end


------------------------------------------------------------------------
-- PAREN CHECKER
-- Validates that all flow-control keywords requiring a condition are
-- immediately followed by a parenthesised condition.
-- Keywords that require ( ... ):  if  elseif  while
-- Keywords that must NOT have (:  else  do  repeat  for (has own syntax)
-- Returns nil on success, or an error string on failure.
-- This runs before transpileBraces so errors halt compilation cleanly.
------------------------------------------------------------------------

-- Keywords that require an immediate ( after them
local COND_KEYWORDS = { ["if"]=true, ["elseif"]=true, ["while"]=true }

local function checkParens(tokens)
  local n = #tokens
  for idx = 1, n do
    local t = tokens[idx]
    if t.k == K.KW and COND_KEYWORDS[t.v] then
      -- Scan forward past spaces/newlines to find the next meaningful token
      local p = idx + 1
      while p <= n and (tokens[p].k==K.SPACE or tokens[p].k==K.NEWLINE or
                        tokens[p].k==K.COMMENT) do
        p = p + 1
      end
      local nxt = tokens[p]
      if not nxt or nxt.k ~= K.LPAREN then
        local got = nxt and ("'" .. nxt.v .. "' (kind=" .. nxt.k .. ")") or "end of file"
        -- collect a few surrounding tokens for context
        local ctx = {}
        for ci = math.max(1, idx-3), math.min(n, idx+5) do
          ctx[#ctx+1] = tokens[ci].v
        end
        return "line " .. t.line .. ": '" .. t.v ..
               "' must be followed by '(' but found " .. got ..
               "\n  context: " .. table.concat(ctx, "") ..
               "\n  hint: write  " .. t.v .. " (condition) { ... }"
      end
    end
  end
  return nil
end

------------------------------------------------------------------------
-- TOKEN STREAM HELPERS
------------------------------------------------------------------------

-- Build a cursor over a token array for stateful walking
local function cursor(tokens)
  local pos = 1
  local n   = #tokens

  local c = {}

  function c.peek(offset)
    local p = pos + (offset or 0)
    return tokens[p] or tok(K.EOF, "", 0)
  end

  function c.cur()  return c.peek(0) end
  function c.next() return c.peek(1) end

  function c.adv()
    local t = tokens[pos]
    pos = pos + 1
    return t
  end

  function c.pos() return pos end
  function c.setPos(p) pos = p end
  function c.done() return pos > n end

  -- Peek at the next meaningful (non-space/comment/newline) token
  function c.peekMeaningful(offset)
    local count = 0
    local p = pos
    while p <= n do
      local t = tokens[p]
      if t.k ~= K.SPACE and t.k ~= K.NEWLINE and t.k ~= K.COMMENT then
        if count == (offset or 0) then return t end
        count = count + 1
      end
      p = p + 1
    end
    return tok(K.EOF, "", 0)
  end

  return c
end

-- Collect all tokens of a stream into an array (flattening any nested structure)
local function toArray(tokens)
  if type(tokens) == "table" and tokens[1] and tokens[1].k then
    return tokens
  end
  return tokens
end

-- Copy a token, optionally overriding fields
local function tokCopy(t, overrides)
  local n = { k=t.k, v=t.v, line=t.line }
  if overrides then
    for k,v in pairs(overrides) do n[k] = v end
  end
  return n
end

------------------------------------------------------------------------
-- TYPE ALIAS TABLE
-- Resolves shorthand type names to canonical Lua type names.
-- Users can extend Sua.typeAliases before calling transpile/check.
------------------------------------------------------------------------

Sua.typeAliases = {
  num=true, str=true, bool=true, fn=true, tbl=true,
  int=true, uint=true,
}

local CANONICAL = {
  num="number", str="string", bool="boolean",
  fn="function", tbl="table", int="number", uint="number",
}

local function resolveAlias(t)
  return CANONICAL[t] or t
end

------------------------------------------------------------------------
-- KNOWN GLOBALS
-- Identifiers that are always in scope; declaration checker ignores them.
------------------------------------------------------------------------

Sua.knownGlobals = {
  -- Lua builtins
  _G=true,_ENV=true,_VERSION=true,
  print=true,pairs=true,ipairs=true,next=true,
  type=true,tostring=true,tonumber=true,
  error=true,assert=true,pcall=true,xpcall=true,
  require=true,load=true,loadfile=true,dofile=true,
  select=true,rawget=true,rawset=true,rawequal=true,rawlen=true,
  setmetatable=true,getmetatable=true,
  unpack=true,table=true,string=true,math=true,
  io=true,os=true,coroutine=true,package=true,debug=true,
  collectgarbage=true,
  -- CC
  shell=true,fs=true,term=true,colors=true,colours=true,
  peripheral=true,redstone=true,rs=true,turtle=true,
  textutils=true,paintutils=true,window=true,multishell=true,
  settings=true,disk=true,http=true,keys=true,
  gps=true,vector=true,parallel=true,rednet=true,
  pocket=true,commands=true,speaker=true,
  self=true,arg=true,
}

------------------------------------------------------------------------
-- STRUCT REGISTRY
-- Populated during the struct pre-pass; consumed by checkers.
------------------------------------------------------------------------

Sua.structs = {}   -- [name] = { fields = { [fname] = typeName } }

------------------------------------------------------------------------
-- SCOPE ANALYSIS
-- Single pass that walks the token stream and annotates each NAME token
-- with .scopeType (declared type or nil) and .declared (bool).
-- Returns a scope_map: array parallel to tokens.
-- Each entry: { declaredType=string|nil, depth=int, known=bool }
------------------------------------------------------------------------

-- Scope stack: array of frames, each frame = { [name] = {type=T, depth=D} }
local function newScope()
  local frames = { {} }

  local function push() frames[#frames+1] = {} end

  local function pop()
    if #frames > 1 then frames[#frames] = nil end
  end

  local function declare(name, typeName, depth)
    frames[#frames][name] = { type=resolveAlias(typeName or "any"), depth=depth or #frames }
  end

  local function get(name)
    for i = #frames, 1, -1 do
      if frames[i][name] then return frames[i][name] end
    end
    return nil
  end

  local function depth() return #frames end

  return { push=push, pop=pop, declare=declare, get=get, depth=depth }
end

-- Walk tokens to build a scope map.
-- Returns scope_map[i] = { type=T } for each token that is a NAME.
local function analyseScope(tokens)
  local scope    = newScope()
  local map      = {}   -- parallel to tokens
  local n        = #tokens
  local i        = 1

  -- Pre-register struct names
  for name, _ in pairs(Sua.structs) do
    scope.declare(name, name)
  end

  -- helpers
  local function skipTrivia()
    while i <= n and (tokens[i].k==K.SPACE or tokens[i].k==K.NEWLINE or tokens[i].k==K.COMMENT) do
      i = i + 1
    end
  end

  local function peekK(offset)
    local p = i + (offset or 0)
    return tokens[p] and tokens[p].k or K.EOF
  end

  local function peekV(offset)
    local p = i + (offset or 0)
    return tokens[p] and tokens[p].v or ""
  end

  -- Consume optional type annotation:  : TypeName  (after a name or )
  -- Returns the type string or nil. Advances i past the annotation if present.
  local function consumeTypeAnnotation()
    local saved = i
    -- skip spaces
    local p = i
    while p <= n and tokens[p].k == K.SPACE do p=p+1 end
    if tokens[p] and tokens[p].k == K.COLON then
      p = p + 1
      while p <= n and tokens[p].k == K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k == K.NAME then
        local typeName = tokens[p].v
        i = p + 1
        return resolveAlias(typeName)
      end
    end
    return nil
  end

  -- Consume optional arrow return type:  -> TypeName
  local function consumeReturnType()
    local p = i
    while p <= n and tokens[p].k == K.SPACE do p=p+1 end
    if tokens[p] and tokens[p].k == K.OP and tokens[p].v == "->" then
      p = p + 1
      while p <= n and tokens[p].k == K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k == K.NAME then
        local rt = resolveAlias(tokens[p].v)
        i = p + 1
        return rt
      end
    end
    return nil
  end

  while i <= n do
    local t = tokens[i]

    -- let / glet / local declarations
    -- `local` appears in the token stream after expandImports converts
    -- `import "x"` to `local alias = dofile(...)`, so we must handle it.
    if t.k == K.KW and (t.v == "let" or t.v == "glet" or t.v == "local") then
      local isGlet = (t.v == "glet")
      i = i + 1
      skipTrivia()
      -- Skip `function` after `local` (local function handled below)
      if tokens[i] and tokens[i].k == K.KW and tokens[i].v == "function" then
        goto continueScope
      end
      if tokens[i] and tokens[i].k == K.NAME then
        local nameIdx = i
        local name    = tokens[i].v
        i = i + 1
        local typeName = consumeTypeAnnotation()
        scope.declare(name, typeName)
        map[nameIdx] = { type=resolveAlias(typeName or "any"), declared=true, depth=scope.depth() }
      end

    -- function declarations
    elseif t.k == K.KW and t.v == "function" then
      i = i + 1
      skipTrivia()
      -- collect name (may be a.b or a:b)
      if tokens[i] and tokens[i].k == K.NAME then
        local nameIdx = i
        local name    = tokens[i].v
        i = i + 1
        -- consume .name or :name suffixes
        while i <= n and (tokens[i].k==K.DOT or tokens[i].k==K.COLON) and
              tokens[i+1] and tokens[i+1].k==K.NAME do
          i = i + 2
        end
        scope.declare(name, "function")
        map[nameIdx] = { type="function", declared=true, depth=scope.depth() }
        -- parameters: scan (...)
        skipTrivia()
        if tokens[i] and tokens[i].k == K.LPAREN then
          i = i + 1
          scope.push()
          while i <= n and tokens[i].k ~= K.RPAREN and tokens[i].k ~= K.EOF do
            if tokens[i].k == K.NAME then
              local pIdx = i
              local pName = tokens[i].v
              i = i + 1
              local pType = consumeTypeAnnotation()
              scope.declare(pName, pType)
              map[pIdx] = { type=resolveAlias(pType or "any"), declared=true, depth=scope.depth() }
            else
              i = i + 1
            end
          end
          if tokens[i] and tokens[i].k == K.RPAREN then i = i + 1 end
          -- consume return type annotation -> T
          consumeReturnType()
        end
      end

    -- for loop variables: declare in current scope (the body's { will
    -- push the inner scope). No extra push needed here.
    elseif t.k == K.KW and t.v == "for" then
      i = i + 1
      skipTrivia()
      while i <= n and tokens[i].k == K.NAME do
        local vIdx = i
        local vName = tokens[i].v
        i = i + 1
        scope.declare(vName, nil)
        map[vIdx] = { type="any", declared=true, depth=scope.depth() }
        skipTrivia()
        if tokens[i] and tokens[i].k == K.COMMA then i=i+1; skipTrivia()
        else break end
      end

    -- struct names (registered globally)
    elseif t.k == K.KW and t.v == "struct" then
      i = i + 1
      skipTrivia()
      if tokens[i] and tokens[i].k == K.NAME then
        local sName = tokens[i].v
        scope.declare(sName, sName)
        map[i] = { type=sName, declared=true, depth=scope.depth() }
        i = i + 1
      end

    -- scope open/close
    elseif t.k == K.LBRACE then
      scope.push(); i = i + 1

    elseif t.k == K.RBRACE then
      scope.pop(); i = i + 1

    -- any other NAME: annotate with current scope info
    elseif t.k == K.NAME then
      local info = scope.get(t.v)
      if info then
        map[i] = { type=info.type, declared=true, depth=info.depth }
      else
        map[i] = { type=nil, declared=false, depth=scope.depth() }
      end
      i = i + 1

    else
      i = i + 1
    end
    ::continueScope::
  end

  return map
end

------------------------------------------------------------------------
-- PRE-PASSES
-- Each pass takes a token array and returns a new token array.
-- Tokens keep their original .line through all passes.
------------------------------------------------------------------------

-- Helper: emit a synthetic token with the source line of a reference token
local function synth(k, v, ref)
  return tok(k, v, ref and ref.line or 0)
end

-- 1. EXPAND ONE-LINERS
--    $$ code   ->  $RAW[ code ]$RAW
--    !!name c  ->  !DBG[name c ]!DBG
--    Operates on the raw source string before tokenization (these are
--    text-level shorthands that don't tokenize cleanly).
--    Returns modified source string.
local function expandOneLiners(src)
  src = src:gsub("%$%$([^\n]*)", function(rest) return "$[" .. rest .. "]$" end)
  src = src:gsub("!!([%a_][%w_]*)([^\n]*)", function(n,r) return "![" .. n .. r .. "]!" end)
  return src
end

-- 2. STRIP RAW BLOCKS
--    $[ ... ]$  ->  RAW token carrying the verbatim Lua
--    Returns modified source string and a stash table.
local function stripRawBlocks(src)
  local stash = {}
  local idx   = 0
  local out   = {}
  local i     = 1
  local len   = #src

  -- Lua patterns don't match \n with `.`, so we scan manually for $[ ... ]$
  -- to correctly handle multiline raw blocks.
  while i <= len do
    local s, e = src:find("%$%[", i)
    if not s then
      out[#out+1] = src:sub(i)
      break
    end
    -- Append source before the opening $[
    out[#out+1] = src:sub(i, s - 1)
    -- Find the closing ]$ scanning from after the $[
    local cs, ce = src:find("%]%$", e + 1)
    local body, nextI
    if cs then
      body  = src:sub(e + 1, cs - 1)
      nextI = ce + 1
    else
      -- Unclosed raw block: treat rest of file as body
      body  = src:sub(e + 1)
      nextI = len + 1
    end
    idx = idx + 1
    local key = "__RAW_" .. idx .. "__"
    stash[key] = body
    -- Preserve line count by replacing with newlines + placeholder
    local nl = 0
    for _ in body:gmatch("\n") do nl = nl + 1 end
    out[#out+1] = string.rep("\n", nl) .. key
    i = nextI
  end

  return table.concat(out), stash
end

-- 3. STRIP DEBUG BLOCKS
--    ![name ... ]!  ->  blank lines (or body if name is enabled)
--    Operates on source string. Returns modified source.
local function stripDebugBlocks(src, enabled)
  local out = {}
  local i   = 1
  local len = #src
  enabled   = enabled or {}

  while i <= len do
    local ns, ne, dname = src:find("!%[([%a_][%w_]*)", i)
    if not ns then out[#out+1] = src:sub(i); break end

    out[#out+1] = src:sub(i, ns-1)

    local bodyStart = ne + 1
    local cs, ce    = src:find("]!", bodyStart, true)
    local body, blockEnd
    if cs then
      body     = src:sub(bodyStart, cs-1)
      blockEnd = ce + 1
    else
      body     = src:sub(bodyStart)
      blockEnd = len + 1
    end

    local keep = (enabled == "__all__") or
                 (type(enabled) == "table" and enabled[dname])
    if keep then
      out[#out+1] = body
    else
      local nl = 0
      for _ in src:sub(ns, blockEnd-1):gmatch("\n") do nl=nl+1 end
      out[#out+1] = string.rep("\n", nl)
    end
    i = blockEnd
  end
  return table.concat(out)
end

-- 4. TOKEN PASS: STRIP TYPE ANNOTATIONS
--    Removes  : TypeName  from parameter lists and variable declarations.
--    Removes  -> TypeName  from function signatures.
--    Works on the token stream; preserves line numbers exactly.
local function stripTypeAnnotations(tokens)
  local out = {}
  local i   = 1
  local n   = #tokens

  -- Helper: skip spaces at position p, return new p
  local function skipSpaces(p)
    while p <= n and tokens[p].k == K.SPACE do p=p+1 end
    return p
  end

  while i <= n do
    local t = tokens[i]

    -- Pattern:  NAME SPACE? COLON SPACE? NAME  where the colon is a type annotation
    -- Only consume if followed by identifier (type name), then comma, ) or =
    if t.k == K.COLON then
      local p = skipSpaces(i+1)
      if tokens[p] and tokens[p].k == K.NAME and not LUA_KEYWORDS[tokens[p].v] then
        local p2 = skipSpaces(p+1)
        local nxt = tokens[p2]
        if nxt and (nxt.k==K.COMMA or nxt.k==K.RPAREN or
                    (nxt.k==K.OP and (nxt.v=="=" or nxt.v=="==" or nxt.v=="->")) or
                    nxt.k==K.LBRACE or nxt.k==K.NEWLINE or nxt.k==K.EOF or
                    nxt.k==K.SEMI) then
          -- Strip the colon and type name (replace with spaces to keep column)
          i = p + 1  -- skip colon + spaces + type name
          goto continue
        end
      end

    -- Arrow return type:  -> TypeName
    elseif t.k == K.OP and t.v == "->" then
      local p = skipSpaces(i+1)
      if tokens[p] and tokens[p].k == K.NAME then
        -- skip -> and type name
        i = skipSpaces(p+1)
        goto continue
      else
        -- bare -> with no type: just skip it
        i = i + 1
        goto continue
      end
    end

    out[#out+1] = t
    i = i + 1
    ::continue::
  end

  return out
end

-- 5. TOKEN PASS: EXPAND KEYWORD SUGAR
--    let   -> local
--    glet  -> (nothing, becomes a bare assignment)
--    global function -> function  (suppress auto-local in emitter)
--    ++ / -- / += etc. -> expanded forms
--    Modifies token values in-place (safe since we copy).
local function expandKeywordSugar(tokens)
  local out = {}
  local i   = 1
  local n   = #tokens

  local function flush(t) out[#out+1] = t end

  -- Collect the l-value expression that was just emitted
  -- Walk back in `out` collecting the lvalue tokens
  local function collectLvalue()
    local lv  = {}
    local j   = #out
    -- skip trailing spaces
    while j >= 1 and out[j].k == K.SPACE do j=j-1 end
    -- collect name, dots, brackets, colons
    while j >= 1 do
      local tk = out[j]
      if tk.k==K.NAME or tk.k==K.DOT or tk.k==K.COLON or
         tk.k==K.LBRACKET or tk.k==K.RBRACKET or
         tk.k==K.NUMBER or tk.k==K.STRING then
        table.insert(lv, 1, tk.v)
        j = j - 1
      elseif tk.k == K.SPACE then
        j = j - 1
      else
        break
      end
    end
    return table.concat(lv)
  end

  while i <= n do
    local t = tokens[i]

    -- let -> local
    if t.k == K.KW and t.v == "let" then
      flush(tokCopy(t, {k=K.KW, v="local"})); i=i+1

    -- glet -> (skip the keyword, becomes plain assignment)
    elseif t.k == K.KW and t.v == "glet" then
      i=i+1

    -- global function -> function  (tag it so emitter skips auto-local)
    elseif t.k == K.KW and t.v == "global" then
      i=i+1
      -- skip spaces
      while i<=n and tokens[i].k==K.SPACE do flush(tokens[i]); i=i+1 end
      if tokens[i] and tokens[i].k==K.KW and tokens[i].v=="function" then
        local ft = tokCopy(tokens[i])
        ft.global = true
        flush(ft); i=i+1
      end

    -- ++ : lvalue = lvalue + 1
    elseif t.k == K.OP and t.v == "++" then
      local lv = collectLvalue()
      flush(synth(K.SPACE, " ", t))
      flush(synth(K.OP, "=", t))
      flush(synth(K.SPACE, " ", t))
      for _, ch in ipairs({lv," ","+", " ","1"}) do
        flush(synth(K.OP, ch, t))
      end
      i=i+1

    -- -- : lvalue = lvalue - 1
    elseif t.k == K.OP and t.v == "--" then
      local lv = collectLvalue()
      flush(synth(K.SPACE, " ", t))
      flush(synth(K.OP, "=", t))
      flush(synth(K.SPACE, " ", t))
      for _,ch in ipairs({lv," ","-"," ","1"}) do
        flush(synth(K.OP, ch, t))
      end
      i=i+1

    -- compound assignment: +=  -=  *=  /=  //=  %=  ^=  ..=
    elseif t.k == K.OP and (t.v:match("^[%+%-%*%/%%^][/]?=$") or t.v=="..=") then
      local opmap = {["+="]="+",["-="]="-",["*="]="*",["/="]="/",
                     ["//="]="//", ["%="]= "%",["^="]=  "^",["..="]= ".."}
      local baseOp = opmap[t.v]
      if baseOp then
        local lv = collectLvalue()
        flush(synth(K.SPACE, " ", t))
        flush(synth(K.OP, "=", t))
        flush(synth(K.SPACE, " ", t))
        flush(synth(K.NAME, lv, t))
        flush(synth(K.SPACE, " ", t))
        flush(synth(K.OP, baseOp, t))
        flush(synth(K.SPACE, " ", t))
        i=i+1
      else
        flush(t); i=i+1
      end

    -- != -> ~=
    elseif t.k == K.OP and t.v == "!=" then
      flush(tokCopy(t, {v="~="})); i=i+1

    else
      flush(t); i=i+1
    end
  end

  return out
end


------------------------------------------------------------------------
-- NAMESPACE EXPANSION
------------------------------------------------------------------------
-- Syntax:
--   namespace Name { ... }           -> local Name = {}; do ... end
--   global namespace Name { ... }    -> Name = {}; do ... end
--
-- Inside a namespace body, declarations are automatically wired:
--   struct Vec2 { ... }       -> Vec2 class created, Name.Vec2 = Vec2
--   function Vec2:method() {} -> normal method, visible via Name.Vec2
--   function helper() {}      -> local function, private to namespace
--   global function foo() {}  -> Name.foo = foo  (exported)
--   let x:num = 5             -> local x (private)
--   glet x:num = 5            -> Name.x = ... (exported)
--   enum Color { ... }        -> local Color, Name.Color = Color
--
-- All structs and global-function/glet/enum declarations are exported
-- onto the namespace table automatically.
-- The body is wrapped in do...end to contain locals.
------------------------------------------------------------------------

local function expandNamespaces(tokens)
  local out = {}
  local i   = 1
  local n   = #tokens
  -- Track namespace names defined at this level so the pipeline
  -- can emit a return statement for library files.
  Sua._lastNamespaces = {}

  local function flush(t)  out[#out+1] = t end
  local function raw(s, r) out[#out+1] = synth(K.RAW, s, r) end

  -- Collect all tokens from position p up to (but not including) the
  -- matching closing brace. Returns { bodyTokens, nextI }.
  local function collectBraceBody(p)
    local body  = {}
    local depth = 1
    p = p + 1  -- skip opening {
    while p <= n and depth > 0 do
      if     tokens[p].k == K.LBRACE then depth = depth + 1
      elseif tokens[p].k == K.RBRACE then
        depth = depth - 1
        if depth == 0 then p = p + 1; break end
      end
      body[#body+1] = tokens[p]
      p = p + 1
    end
    return body, p
  end

  -- Scan a namespace body token array and collect the names of things
  -- that should be exported onto the namespace table:
  --   struct Name      -> always exported
  --   global function  -> exported
  --   glet name        -> exported
  --   global enum      -> exported
  -- Returns a list of { kind, name } entries.
  local function collectExports(bodyToks)
    local exports = {}
    local bm = #bodyToks
    local bj = 1
    while bj <= bm do
      local bt = bodyToks[bj]

      -- struct Name { } -> export Name
      if bt.k==K.KW and bt.v=="struct" then
        local p = bj+1
        while p<=bm and bodyToks[p].k==K.SPACE do p=p+1 end
        if bodyToks[p] and bodyToks[p].k==K.NAME then
          exports[#exports+1] = { kind="struct", name=bodyToks[p].v, ref=bt }
        end

      -- global function Name -> export Name
      elseif bt.k==K.KW and bt.v=="global" then
        local p = bj+1
        while p<=bm and bodyToks[p].k==K.SPACE do p=p+1 end
        if bodyToks[p] and bodyToks[p].k==K.KW and bodyToks[p].v=="function" then
          local p2 = p+1
          while p2<=bm and bodyToks[p2].k==K.SPACE do p2=p2+1 end
          if bodyToks[p2] and bodyToks[p2].k==K.NAME then
            exports[#exports+1] = { kind="function", name=bodyToks[p2].v, ref=bt }
          end
        elseif bodyToks[p] and bodyToks[p].k==K.KW and bodyToks[p].v=="enum" then
          local p2 = p+1
          while p2<=bm and bodyToks[p2].k==K.SPACE do p2=p2+1 end
          if bodyToks[p2] and bodyToks[p2].k==K.NAME then
            exports[#exports+1] = { kind="enum", name=bodyToks[p2].v, ref=bt }
          end
        end

      -- glet name -> export name
      elseif bt.k==K.KW and bt.v=="glet" then
        local p = bj+1
        while p<=bm and bodyToks[p].k==K.SPACE do p=p+1 end
        if bodyToks[p] and bodyToks[p].k==K.NAME then
          exports[#exports+1] = { kind="var", name=bodyToks[p].v, ref=bt }
        end
      end

      bj = bj + 1
    end
    return exports
  end

  -- Rewrite the body tokens:
  --   `global function` -> plain `function` (will be auto-local by transpiler,
  --                         then exported via nsName.foo = foo at end)
  --   `global enum`     -> plain `enum`
  --   Top-level commas  -> dropped (users may write  struct A{}, function B(){}  )
  --   struct stays as-is (expandStructs handles it later; we export the name)
  --   glet stays as-is (expandKeywordSugar strips glet; we export the name)
  local function rewriteBody(bodyToks)
    local rewritten = {}
    local bm = #bodyToks
    local bj = 1
    -- Track brace AND paren depth so we only drop commas that separate
    -- top-level declarations, not commas inside parameter lists or tables.
    local braceDepth = 0
    local parenDepth  = 0
    while bj <= bm do
      local bt = bodyToks[bj]

      if bt.k == K.LBRACE  then braceDepth = braceDepth + 1 end
      if bt.k == K.RBRACE  then braceDepth = braceDepth - 1 end
      if bt.k == K.LPAREN  then parenDepth  = parenDepth  + 1 end
      if bt.k == K.RPAREN  then parenDepth  = parenDepth  - 1 end

      -- Drop commas only at the top level (between declarations),
      -- never inside parens (function params) or braces (tables/structs)
      if bt.k == K.COMMA and braceDepth == 0 and parenDepth == 0 then
        bj = bj + 1; goto continueRewrite
      end

      -- Drop `global` keyword before function/enum inside namespace.
      -- Set bj to point at the function/enum token so it gets processed
      -- normally on this iteration (fall through to rewritten append).
      if bt.k==K.KW and bt.v=="global" and braceDepth==0 and parenDepth==0 then
        local p = bj+1
        while p<=bm and bodyToks[p].k==K.SPACE do p=p+1 end
        local nxt = bodyToks[p]
        if nxt and nxt.k==K.KW and
           (nxt.v=="function" or nxt.v=="enum") then
          -- Skip `global` and any spaces; reprocess from function/enum
          bj = p
          bt = bodyToks[bj]
          -- fall through: bt is now `function` or `enum`, gets appended below
        end
      end

      rewritten[#rewritten+1] = bt
      ::continueRewrite::
      bj = bj + 1
    end
    return rewritten
  end

  while i <= n do
    local t = tokens[i]

    local isGlobal = false

    -- helper: skip spaces and newlines
    local function skipWS(p)
      while p<=n and (tokens[p].k==K.SPACE or tokens[p].k==K.NEWLINE or
                      tokens[p].k==K.COMMENT) do p=p+1 end
      return p
    end

    -- Detect  global namespace Name {
    if t.k==K.KW and t.v=="global" then
      local p = skipWS(i+1)
      if tokens[p] and tokens[p].k==K.NAME and tokens[p].v=="namespace" then
        isGlobal = true
        i = p  -- advance to `namespace` NAME token
        t = tokens[i]
      else
        flush(t); i=i+1; goto contNS
      end
    end

    -- Detect  namespace Name {
    if t.k==K.NAME and t.v=="namespace" then
      local ref  = t
      local j    = skipWS(i+1)

      -- Expect namespace name
      if not (tokens[j] and tokens[j].k==K.NAME) then
        flush(t); i=i+1; goto contNS
      end
      local nsName = tokens[j].v
      j = skipWS(j+1)

      -- Expect {
      if not (tokens[j] and tokens[j].k==K.LBRACE) then
        flush(t); i=i+1; goto contNS
      end

      -- Collect the namespace body
      local bodyToks, nextI = collectBraceBody(j)
      i = nextI

      -- Analyse exports before rewriting
      local exports = collectExports(bodyToks)

      -- Rewrite body (strip `global` prefix from inner function/enum)
      local rewrittenBody = rewriteBody(bodyToks)

      -- Emit:
      --   local nsName = {}   (or bare for global namespace)
      --   do
      --     <rewritten body>
      --     nsName.Foo = Foo  (for each export)
      --   end
      local prefix = isGlobal and "" or "local "
      -- Track namespace name for module return generation
      Sua._lastNamespaces[#Sua._lastNamespaces+1] = nsName
      raw(prefix .. nsName .. " = {}\ndo\n", ref)

      -- Emit rewritten body tokens
      for _, bt in ipairs(rewrittenBody) do
        out[#out+1] = bt
      end

      -- Emit export assignments
      raw("\n", ref)
      for _, exp in ipairs(exports) do
        raw(nsName .. "." .. exp.name .. " = " .. exp.name .. "\n", exp.ref)
      end
      raw("end\n", ref)

    else
      flush(t); i=i+1
    end
    ::contNS::
  end

  return out
end

-- 6. TOKEN PASS: EXPAND STRUCTS
--    struct Name { field:Type = default, ... }
--    -> local Name = {}; Name.__index = Name; function Name.new(...) ... end; ...
local function expandStructs(tokens)
  local out  = {}
  local i    = 1
  local n    = #tokens

  local function flush(t) out[#out+1] = t end
  local function flushRaw(s, ref) flush(synth(K.RAW, s, ref)) end

  -- Parse one struct field from a token sub-sequence
  -- Returns { name, type, default } or nil
  local function parseField(toks)
    local j = 1
    local m = #toks
    -- skip leading space
    while j<=m and toks[j].k==K.SPACE do j=j+1 end
    if j>m or toks[j].k~=K.NAME then return nil end
    local fname = toks[j].v; j=j+1
    -- optional : Type
    local ftype = "any"
    while j<=m and toks[j].k==K.SPACE do j=j+1 end
    if j<=m and toks[j].k==K.COLON then
      j=j+1
      while j<=m and toks[j].k==K.SPACE do j=j+1 end
      if j<=m and toks[j].k==K.NAME then ftype=resolveAlias(toks[j].v); j=j+1 end
    end
    -- optional = default
    local fdefault = "nil"
    while j<=m and toks[j].k==K.SPACE do j=j+1 end
    if j<=m and toks[j].k==K.OP and toks[j].v=="=" then
      j=j+1
      while j<=m and toks[j].k==K.SPACE do j=j+1 end
      local parts = {}
      while j<=m do parts[#parts+1]=toks[j].v; j=j+1 end
      fdefault = table.concat(parts):match("^%s*(.-)%s*$")
    end
    return { name=fname, type=ftype, default=fdefault }
  end

  while i <= n do
    local t = tokens[i]

    if t.k == K.KW and (t.v == "struct" or t.v == "global") then
      local isGlobal = (t.v == "global")
      local refLine  = t.line
      local j = i + 1

      -- skip spaces
      while j<=n and tokens[j].k==K.SPACE do j=j+1 end

      -- if global, expect 'struct' next
      if isGlobal then
        if not (tokens[j] and tokens[j].k==K.KW and tokens[j].v=="struct") then
          flush(t); i=i+1; goto continueStruct
        end
        j=j+1
        while j<=n and tokens[j].k==K.SPACE do j=j+1 end
      end

      -- expect struct name
      if not (tokens[j] and tokens[j].k==K.NAME) then
        flush(t); i=i+1; goto continueStruct
      end

      local sName = tokens[j].v
      j=j+1

      -- skip spaces to {
      while j<=n and (tokens[j].k==K.SPACE or tokens[j].k==K.NEWLINE) do j=j+1 end
      if not (tokens[j] and tokens[j].k==K.LBRACE) then
        flush(t); i=i+1; goto continueStruct
      end
      j=j+1  -- skip {

      -- Collect body tokens until matching }
      local bodyToks = {}
      local depth = 1
      while j<=n and depth>0 do
        if tokens[j].k==K.LBRACE then depth=depth+1
        elseif tokens[j].k==K.RBRACE then
          depth=depth-1
          if depth==0 then j=j+1; break end
        end
        bodyToks[#bodyToks+1] = tokens[j]
        j=j+1
      end

      -- Split body on commas (respecting brace depth) to get field token groups
      local fieldGroups = {{}}
      local fd = 0
      for _, bt in ipairs(bodyToks) do
        if bt.k==K.LBRACE then fd=fd+1; fieldGroups[#fieldGroups][#fieldGroups[#fieldGroups]+1]=bt
        elseif bt.k==K.RBRACE then fd=fd-1; fieldGroups[#fieldGroups][#fieldGroups[#fieldGroups]+1]=bt
        elseif bt.k==K.COMMA and fd==0 then fieldGroups[#fieldGroups+1]={}
        elseif bt.k~=K.NEWLINE then fieldGroups[#fieldGroups][#fieldGroups[#fieldGroups]+1]=bt
        end
      end

      local fields = {}
      for _, fg in ipairs(fieldGroups) do
        local f = parseField(fg)
        if f then fields[#fields+1] = f end
      end

      -- Register in struct table for checkers
      local structInfo = { fields={} }
      for _, f in ipairs(fields) do structInfo.fields[f.name] = f.type end
      Sua.structs[sName] = structInfo

      -- Emit class table + new() + __tostring
      local prefix = isGlobal and "" or "local "
      local paramNames = {}
      for _, f in ipairs(fields) do paramNames[#paramNames+1] = f.name end

      local code = {}
      code[#code+1] = prefix .. sName .. " = {}"
      code[#code+1] = sName .. ".__index = " .. sName
      -- new() accepts both dot and colon call
      code[#code+1] = "function " .. sName .. ".new(self_or_first, " .. table.concat(paramNames, ", ") .. ")"
      code[#code+1] = "  if self_or_first ~= " .. sName .. " then"
      if #paramNames > 0 then
        code[#code+1] = "    " .. paramNames[1] .. " = self_or_first"
      end
      code[#code+1] = "  end"
      code[#code+1] = "  local self = setmetatable({}, " .. sName .. ")"
      for _, f in ipairs(fields) do
        if f.default == "nil" then
          code[#code+1] = "  self." .. f.name .. " = " .. f.name
        else
          code[#code+1] = "  self." .. f.name .. " = " .. f.name ..
                          " ~= nil and " .. f.name .. " or " .. f.default
        end
      end
      code[#code+1] = "  return self"
      code[#code+1] = "end"
      -- __tostring
      local tsParts = {}
      for _, f in ipairs(fields) do
        tsParts[#tsParts+1] = '"' .. f.name .. '=" .. tostring(self.' .. f.name .. ')'
      end
      code[#code+1] = "function " .. sName .. ":__tostring()"
      code[#code+1] = '  return "' .. sName .. ' { " .. ' ..
                      table.concat(tsParts, ' .. ", " .. ') .. ' .. " }"'
      code[#code+1] = "end"

      flushRaw(table.concat(code, "\n"), t)
      i = j

    else
      flush(t); i=i+1
    end
    ::continueStruct::
  end

  return out
end

-- 7. TOKEN PASS: EXPAND ENUMS
--    enum Name { A, B, C }  ->  local Name = { A=1, B=2, C=3 }
local function expandEnums(tokens)
  local out = {}
  local i   = 1
  local n   = #tokens

  while i <= n do
    local t = tokens[i]
    local isGlobal = false

    if t.k==K.KW and t.v=="global" then
      -- peek for enum
      local p = i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.KW and tokens[p].v=="enum" then
        isGlobal = true; i = p
        t = tokens[i]
      else
        out[#out+1] = t; i=i+1; goto continueEnum
      end
    end

    if t.k == K.KW and t.v == "enum" then
      local refLine = t.line
      local j = i+1
      while j<=n and tokens[j].k==K.SPACE do j=j+1 end
      if not (tokens[j] and tokens[j].k==K.NAME) then
        out[#out+1]=t; i=i+1; goto continueEnum
      end
      local eName = tokens[j].v; j=j+1
      while j<=n and (tokens[j].k==K.SPACE or tokens[j].k==K.NEWLINE) do j=j+1 end
      if not (tokens[j] and tokens[j].k==K.LBRACE) then
        out[#out+1]=t; i=i+1; goto continueEnum
      end
      j=j+1
      -- collect names
      local items = {}
      while j<=n and tokens[j].k~=K.RBRACE and tokens[j].k~=K.EOF do
        if tokens[j].k==K.NAME then items[#items+1]=tokens[j].v end
        j=j+1
      end
      if tokens[j] and tokens[j].k==K.RBRACE then j=j+1 end
      local fields = {}
      for idx, name in ipairs(items) do fields[#fields+1] = name .. "=" .. idx end
      local prefix = isGlobal and "" or "local "
      out[#out+1] = synth(K.RAW, prefix .. eName .. " = {" .. table.concat(fields, ", ") .. "}", t)
      i = j
    else
      out[#out+1]=t; i=i+1
    end
    ::continueEnum::
  end
  return out
end

-- 8. TOKEN PASS: EXPAND DEFINES
--    define NAME value  ->  removed; occurrences of NAME replaced
local function expandDefines(tokens)
  -- First pass: collect defines
  local defines     = {}
  local defineOrder = {}
  local filtered    = {}

  local i = 1
  local n = #tokens
  while i <= n do
    local t = tokens[i]
    if t.k==K.KW and t.v=="define" then
      -- consume: define NAME rest-of-line
      i=i+1
      while i<=n and tokens[i].k==K.SPACE do i=i+1 end
      if tokens[i] and tokens[i].k==K.NAME then
        local dname = tokens[i].v; i=i+1
        local parts = {}
        while i<=n and tokens[i].k~=K.NEWLINE and tokens[i].k~=K.EOF do
          if tokens[i].k~=K.SPACE or #parts>0 then parts[#parts+1]=tokens[i].v end
          i=i+1
        end
        local val = table.concat(parts):match("^(.-)%s*$")
        if not defines[dname] then defineOrder[#defineOrder+1]=dname end
        defines[dname] = val
      end
    else
      filtered[#filtered+1]=t; i=i+1
    end
  end

  -- Sort longer names first to avoid partial replacements
  table.sort(defineOrder, function(a,b) return #a > #b end)

  -- Second pass: replace NAME tokens that match a define
  local out = {}
  for _, t in ipairs(filtered) do
    if t.k==K.NAME and defines[t.v] then
      out[#out+1] = tokCopy(t, {k=K.RAW, v=defines[t.v]})
    else
      out[#out+1] = t
    end
  end
  return out
end

-- 9. TOKEN PASS: EXPAND SWITCH
--    switch expr { case val { } ... default { } }
--    -> if expr == val then ... end
local function expandSwitch(tokens)
  local out = {}
  local i   = 1
  local n   = #tokens

  local function flush(t) out[#out+1] = t end
  local function flushRaw(s, ref) flush(synth(K.RAW, s, ref)) end

  -- Collect all tokens from pos p up to (but not including) the matching }
  -- Returns { bodyTokens, nextI }
  local function collectBody(p)
    local body  = {}
    local depth = 1
    p = p + 1  -- skip opening {
    while p <= n and depth > 0 do
      if tokens[p].k==K.LBRACE then depth=depth+1
      elseif tokens[p].k==K.RBRACE then
        depth=depth-1
        if depth==0 then p=p+1; break end
      end
      body[#body+1] = tokens[p]
      p=p+1
    end
    return body, p
  end

  -- Turn a body token array into a string
  local function bodyToStr(toks)
    local parts = {}
    for _, t in ipairs(toks) do parts[#parts+1] = t.v end
    return table.concat(parts)
  end

  -- Build a condition string from a case pattern and expression
  local function buildCond(expr, pattern)
    pattern = pattern:match("^%s*(.-)%s*$")
    -- comparison:  > val  >= val  < val  <= val  ~= val  != val
    local op, val = pattern:match("^([<>~!][=]?)%s*(.+)$")
    if op then
      if op=="!=" then op="~=" end
      return expr .. " " .. op .. " " .. val
    end
    -- type check:  is TypeName
    local tname = pattern:match("^is%s+([%a_][%w_]*)$")
    if tname then return 'type(' .. expr .. ') == "' .. tname .. '"' end
    -- equality
    return expr .. " == " .. pattern
  end

  while i <= n do
    local t = tokens[i]

    if t.k==K.KW and t.v=="switch" then
      local refLine = t.line
      i=i+1

      -- Collect the expression tokens up to {
      local exprToks = {}
      local parenD   = 0
      while i<=n do
        local et = tokens[i]
        if et.k==K.LPAREN then parenD=parenD+1; exprToks[#exprToks+1]=et; i=i+1
        elseif et.k==K.RPAREN then
          parenD=parenD-1; exprToks[#exprToks+1]=et; i=i+1
        elseif et.k==K.LBRACE and parenD==0 then break
        else exprToks[#exprToks+1]=et; i=i+1
        end
      end
      local exprStr = bodyToStr(exprToks):match("^%s*(.-)%s*$")

      if tokens[i] and tokens[i].k~=K.LBRACE then
        -- malformed: pass through
        flushRaw("switch " .. exprStr, t); goto contSwitch
      end

      -- Collect switch body
      local switchBody, nextI = collectBody(i)
      i = nextI

      -- Parse cases from switchBody
      local cases  = {}
      local j      = 1
      local bn     = #switchBody

      while j <= bn do
        -- skip trivia
        while j<=bn and (switchBody[j].k==K.SPACE or switchBody[j].k==K.NEWLINE or
                          switchBody[j].k==K.COMMENT) do j=j+1 end
        if j>bn then break end

        local ct = switchBody[j]
        if ct.k==K.KW and ct.v=="case" then
          j=j+1
          -- collect pattern tokens up to {
          local patToks = {}
          local pd = 0
          while j<=bn do
            local pt = switchBody[j]
            if pt.k==K.LPAREN then pd=pd+1; patToks[#patToks+1]=pt; j=j+1
            elseif pt.k==K.RPAREN then pd=pd-1; patToks[#patToks+1]=pt; j=j+1
            elseif pt.k==K.LBRACE and pd==0 then break
            else patToks[#patToks+1]=pt; j=j+1
            end
          end
          local patStr = bodyToStr(patToks):match("^%s*(.-)%s*$")

          if switchBody[j] and switchBody[j].k==K.LBRACE then
            local caseBody, nj = collectBody(j)
            j = nj
            -- Split pattern on commas for multi-value cases
            local conds = {}
            for pat in (patStr .. ","):gmatch("([^,]+),") do
              pat = pat:match("^%s*(.-)%s*$")
              if pat ~= "" then conds[#conds+1] = buildCond(exprStr, pat) end
            end
            cases[#cases+1] = { conds=conds, body=caseBody, isDefault=false }
          end

        elseif ct.k==K.KW and ct.v=="default" then
          j=j+1
          while j<=bn and (switchBody[j].k==K.SPACE or switchBody[j].k==K.NEWLINE) do j=j+1 end
          if switchBody[j] and switchBody[j].k==K.LBRACE then
            local caseBody, nj = collectBody(j)
            j = nj
            cases[#cases+1] = { conds={}, body=caseBody, isDefault=true }
          end
        else
          j=j+1
        end
      end

      -- Emit if/elseif/else chain
      if #cases == 0 then flushRaw("do end", t); goto contSwitch end

      for ci, c in ipairs(cases) do
        if c.isDefault then
          flushRaw("\nelse\n", t)
        elseif ci == 1 then
          flushRaw("\nif " .. table.concat(c.conds, " or ") .. " then\n", t)
        else
          flushRaw("\nelseif " .. table.concat(c.conds, " or ") .. " then\n", t)
        end
        for _, bt in ipairs(c.body) do flush(bt) end
      end
      flushRaw("\nend\n", t)

      ::contSwitch::
    else
      flush(t); i=i+1
    end
  end

  return out
end

-- 10. TOKEN PASS: BRACE -> KEYWORD TRANSPILATION
--     This is the core pass that converts BraceLua brace blocks to Lua
--     keyword blocks (then/do/end etc.)
local function transpileBraces(tokens)
  local out   = {}
  local i     = 1
  local n     = #tokens

  -- pending: what opener keyword to emit when { is encountered
  --   "then" | "do" | "do_block" | "function" | "else" | "repeat"
  local pending         = nil
  local pendingSavedAt  = 0   -- paren depth at which pending was set
  local parenDepth      = 0

  -- Block stack: each frame = { closeWord, isRepeat }
  local blockStack = {}
  -- Brace kind stack: parallel to ALL braces (blocks and tables)
  -- "block" = this { opened a block; "table" = this { is a table constructor
  local braceKind = {}

  local function flush(t) out[#out+1] = t end
  local function emit(s, ref) flush(synth(K.RAW, s, ref)) end

  -- Peek forward past trivia
  local function peekMeaningful(p)
    while p <= n do
      local t = tokens[p]
      if t.k~=K.SPACE and t.k~=K.NEWLINE and t.k~=K.COMMENT then return t end
      p=p+1
    end
    return tok(K.EOF,"",0)
  end

  -- Collect lvalue from output buffer (walk back)
  local function collectLvalue()
    local parts = {}
    local j     = #out
    while j>=1 and out[j].k==K.SPACE do j=j-1 end
    while j>=1 do
      local tk = out[j]
      if tk.k==K.NAME or tk.k==K.DOT or tk.k==K.COLON or
         tk.k==K.LBRACKET or tk.k==K.RBRACKET or
         tk.k==K.NUMBER or tk.k==K.STRING or tk.k==K.RAW then
        table.insert(parts, 1, tk.v); j=j-1
      elseif tk.k==K.SPACE then j=j-1
      else break end
    end
    return table.concat(parts)
  end

  -- Handle opening { for a block
  local function handleOpen(t)
    local opener   = ""
    local isRepeat = false
    if     pending=="then"      then opener="then"
    elseif pending=="do"        then opener="do"
    elseif pending=="do_block"  then opener="do"
    elseif pending=="function"  then opener=""
    elseif pending=="else"      then opener=""
    elseif pending=="repeat"    then opener=""; isRepeat=true
    end
    pending = nil
    blockStack[#blockStack+1] = { closeWord="end", isRepeat=isRepeat }
    braceKind[#braceKind+1] = "block"
    if opener~="" then emit(" "..opener, t) end
  end

  -- Handle closing } for a block
  local function handleClose(t)
    local frame = blockStack[#blockStack]
    blockStack[#blockStack] = nil
    braceKind[#braceKind] = nil
    if frame.isRepeat then return end  -- closing } of repeat: dropped
    local nxt = peekMeaningful(i+1)
    local isCont = nxt.k==K.KW and (nxt.v=="elseif" or nxt.v=="else")
    if not isCont then emit("\n"..frame.closeWord, t) end
  end

  -- Handle a function keyword: determine if auto-local needed
  local function handleFunction(t)
    local p = i+1
    while p<=n and tokens[p].k==K.SPACE do p=p+1 end
    local isMethod = false
    if tokens[p] and tokens[p].k==K.NAME then
      local p2 = p+1
      while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
      if tokens[p2] and (tokens[p2].k==K.DOT or tokens[p2].k==K.COLON) then
        isMethod = true
      end
    end
    if not t.global and not isMethod then emit("local ", t) end
    emit("function", t)
    return "function"
  end

  local pendingSaveStack = {}

  while i <= n do
    local t = tokens[i]

    if t.k == K.KW then
      local v = t.v
      if     v=="if"     then emit("if", t);     pending="then";     i=i+1
      elseif v=="elseif" then emit("elseif", t); pending="then";     i=i+1
      elseif v=="while"  then emit("while", t);  pending="do";       i=i+1
      elseif v=="for"    then emit("for", t);    pending="do";       i=i+1
      elseif v=="do"     then emit("do", t);     pending="do_block"; i=i+1
      elseif v=="repeat" then emit("repeat", t); pending="repeat";   i=i+1
      elseif v=="else"   then
        -- plain else only: else (cond) syntax has been removed
        emit("else", t); pending="else"; i=i+1
      elseif v=="function" then
        pending = handleFunction(t); i=i+1
      elseif v=="until"  then emit("until", t); i=i+1
      elseif v=="return" then emit("return", t); i=i+1
      elseif v=="local"  then emit("local", t);  i=i+1
      else
        -- Other keywords (end, break, goto, etc.) pass through
        emit(v, t); i=i+1
      end

    elseif t.k == K.LBRACE then
      if pending then
        handleOpen(t)
      else
        -- table constructor: push "table" so matching } knows not to emit end
        braceKind[#braceKind+1] = "table"
        flush(t)
      end
      i=i+1

    elseif t.k == K.RBRACE then
      local kind = braceKind[#braceKind]
      if kind == "block" then
        handleClose(t)
      else
        -- table constructor closing brace or unmatched }
        if #braceKind > 0 then braceKind[#braceKind] = nil end
        flush(t)
      end
      i=i+1

    elseif t.k == K.LPAREN then
      parenDepth=parenDepth+1
      if pending and parenDepth > pendingSavedAt+1 then
        pendingSaveStack[#pendingSaveStack+1]=pending
        pending=nil
      else
        pendingSaveStack[#pendingSaveStack+1]=false
      end
      flush(t); i=i+1

    elseif t.k == K.RPAREN then
      local saved = pendingSaveStack[#pendingSaveStack]
      pendingSaveStack[#pendingSaveStack]=nil
      if saved then pending=saved end
      parenDepth=parenDepth-1
      flush(t); i=i+1

    elseif t.k==K.NAME or t.k==K.NUMBER or t.k==K.STRING or
           t.k==K.OP or t.k==K.DOT or t.k==K.DOTDOT or
           t.k==K.DOTDOTDOT or t.k==K.COLON or t.k==K.DCOLON or
           t.k==K.COMMA or t.k==K.SEMI or t.k==K.LBRACKET or
           t.k==K.RBRACKET or t.k==K.SPACE or t.k==K.NEWLINE then
      -- Expression/identifier tokens: reset pending on newlines
      -- only if pending was "else" or we're clearly done
      flush(t); i=i+1

    elseif t.k==K.RAW then
      flush(t); i=i+1

    else
      flush(t); i=i+1
    end
  end

  return out
end

-- Restore raw block placeholders in the final output
local function restoreRawBlocks(tokens, stash)
  if not stash then return tokens end
  local out = {}
  for _, t in ipairs(tokens) do
    if t.k==K.NAME and stash[t.v] then
      out[#out+1] = tokCopy(t, {k=K.RAW, v=stash[t.v]})
    else
      out[#out+1] = t
    end
  end
  return out
end

------------------------------------------------------------------------
-- EMITTER
-- Walks the final token stream and builds the Lua output string.
------------------------------------------------------------------------

local function emit(tokens)
  local parts = {}
  for _, t in ipairs(tokens) do
    if t.k ~= K.COMMENT then
      parts[#parts+1] = t.v
    end
  end
  return table.concat(parts)
end


------------------------------------------------------------------------
-- FILE I/O  (CC fs API with fallback to standard io)
------------------------------------------------------------------------

local function readFile(path)
  if fs then
    if not fs.exists(path) then return nil, "not found: "..path end
    local f = fs.open(path, "r")
    if not f then return nil, "cannot open: "..path end
    local s = f.readAll(); f.close(); return s
  else
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local s = f:read("*a"); f:close(); return s
  end
end

local function writeFile(path, content)
  if fs then
    local f = fs.open(path, "w")
    if not f then return false, "cannot write: "..path end
    f.write(content); f.close(); return true
  else
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content); f:close(); return true
  end
end

------------------------------------------------------------------------
-- IMPORT SYSTEM
------------------------------------------------------------------------
-- Compiled .lua files can carry an embedded type header used by the
-- checkers for cross-file type validation.
--
-- Header format (embedded as a Lua long-comment at the top of .lua):
--   --[[bracelua:header
--   return { version=1, source="file.sua", exports={ ... } }
--   --]]
--
-- exports table:
--   funcName  = { kind="function", params={{name,type},...}, ret="type"|nil }
--   varName   = { kind="var",      type="type" }
--   StructName= { kind="struct",   fields={fieldName="type",...} }
--   EnumName  = { kind="enum",     values={Name=number,...} }
--
-- BraceLua syntax:
--   import "path/to/lib"          -> local lib = dofile("path/to/lib.lua")
--   import "path/to/lib" as mylib -> local mylib = dofile("path/to/lib.lua")
--
-- The import keyword is stripped by expandImports; at runtime it becomes
-- a plain dofile / require call. At check-time the header is loaded and
-- all exported names are registered in the import scope.
------------------------------------------------------------------------

-- Shared import registry: filled by loadHeader, read by checkers.
-- importedModules[alias] = { exports = { name -> exportEntry } }
Sua.importedModules = {}

-- Serialise a Lua value to a compact string (for header generation).
-- Only handles the types we emit: strings, numbers, booleans, nil, tables.
local function serialise(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string"  then return string.format("%q", v) end
  if t == "number"  then return tostring(v) end
  if t == "boolean" then return tostring(v) end
  if t == "nil"     then return "nil" end
  if t == "table"   then
    local parts = {}
    local inner = indent .. "  "
    -- check if array-like
    local isArr = #v > 0
    if isArr then
      for _, item in ipairs(v) do
        parts[#parts+1] = inner .. serialise(item, inner)
      end
    else
      for k, val in pairs(v) do
        local key = type(k)=="string" and k:match("^[%a_][%w_]*$")
                    and k or ("[" .. serialise(k) .. "]")
        parts[#parts+1] = inner .. key .. " = " .. serialise(val, inner)
      end
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  return tostring(v)
end

-- Generate a header table from a BraceLua source file.
-- Analyses the source and collects all top-level exports:
--   glet / global function / global struct / global enum
-- Returns the header as a Lua-evaluable string.
local function generateHeader(src, sourceName)
  sourceName = sourceName or "unknown"

  -- Run the analysis pipeline (no transpile, just analyse)
  local clean = expandOneLiners(src)
  clean = stripDebugBlocks(clean, nil)
  local rawClean, _stash = stripRawBlocks(clean)
  local tokens = tokenize(rawClean)
  tokens = expandStructs(tokens)   -- populates Sua.structs
  tokens = expandEnums(tokens)
  local scopeMap = analyseScope(tokens)

  local exports = {}
  local n = #tokens

  -- Walk tokens collecting top-level exports
  local i = 1
  while i <= n do
    local t = tokens[i]

    -- global function name(params)->retType
    if t.k==K.KW and t.v=="global" then
      local p = i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.KW and tokens[p].v=="function" then
        p=p+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k==K.NAME then
          local fname = tokens[p].v
          p=p+1
          -- collect params from (...)
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          local params = {}
          if tokens[p] and tokens[p].k==K.LPAREN then
            p=p+1
            while p<=n and tokens[p].k~=K.RPAREN and tokens[p].k~=K.EOF do
              if tokens[p].k==K.NAME then
                local pname = tokens[p].v
                local ptype = "any"
                local p2 = p+1
                while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
                if tokens[p2] and tokens[p2].k==K.COLON then
                  p2=p2+1
                  while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
                  if tokens[p2] and tokens[p2].k==K.NAME then
                    ptype = resolveAlias(tokens[p2].v)
                  end
                end
                params[#params+1] = {pname, ptype}
              end
              p=p+1
            end
            if tokens[p] then p=p+1 end  -- skip )
          end
          -- collect return type
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          local ret = nil
          if tokens[p] and tokens[p].k==K.OP and tokens[p].v=="->" then
            p=p+1
            while p<=n and tokens[p].k==K.SPACE do p=p+1 end
            if tokens[p] and tokens[p].k==K.NAME then
              ret = resolveAlias(tokens[p].v)
            end
          end
          exports[fname] = { kind="function", params=params, ret=ret }
        end
      end

    -- glet name:type = ...
    elseif t.k==K.KW and t.v=="glet" then
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.NAME then
        local vname = tokens[p].v
        p=p+1
        local vtype = "any"
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k==K.COLON then
          p=p+1
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          if tokens[p] and tokens[p].k==K.NAME then
            vtype = resolveAlias(tokens[p].v)
          end
        end
        exports[vname] = { kind="var", type=vtype }
      end
    end

    i=i+1
  end

  -- Add structs (from Sua.structs, populated by expandStructs)
  -- Only export global structs -- we detect them by checking if
  -- `global struct Name` appears in the source
  local cleanSrcForStructs = rawClean
  for sname, sinfo in pairs(Sua.structs) do
    -- Check if this struct was declared globally
    if cleanSrcForStructs:find("global%s+struct%s+" .. sname) then
      exports[sname] = { kind="struct", fields=sinfo.fields }
    end
  end

  -- Add enums: scan for global enum declarations
  for line in (rawClean .. "\n"):gmatch("([^\n]*)\n") do
    local ename = line:match("^%s*global%s+enum%s+([%a_][%w_]*)%s*{(.*)}")
    if ename then
      local vals = {}
      local idx = 1
      for item in line:match("{(.*)}"):gmatch("[%a_][%w_]*") do
        vals[item] = idx; idx=idx+1
      end
      exports[ename] = { kind="enum", values=vals }
    end
  end

  local header = {
    version  = 1,
    source   = sourceName,
    exports  = exports,
  }
  return "--[[bracelua:header\n" .. serialise(header) .. "\n--]]\n"
end

-- Load a header from a compiled .lua file (or a .sua.h sidecar).
-- Returns the exports table or nil.
local function loadHeader(luaPath)
  -- Try embedded header in .lua file
  local content, err = readFile(luaPath)
  if content then
    local headerBody = content:match("^%-%-%%[%[bracelua:header%s*(.-)%s*%-%-%]%]")
    if headerBody then
      local fn = load("return " .. headerBody)
      if fn then
        local ok, data = pcall(fn)
        if ok and type(data)=="table" then return data.exports end
      end
    end
  end
  -- Try sidecar .sua.h file
  local sidecar = luaPath:gsub("%.lua$", "") .. ".sua.h"
  local sc, _ = readFile(sidecar)
  if sc then
    local fn = load("return " .. sc)
    if fn then
      local ok, data = pcall(fn)
      if ok and type(data)=="table" then return data.exports end
    end
  end
  return nil
end

-- TOKEN PASS: EXPAND IMPORTS
-- import "path" [as alias]  ->  local alias = dofile("path.lua")
-- Also loads headers into Sua.importedModules for checkers.
-- Takes an optional resolver function(path) -> luaFilePath.
local function expandImports(tokens, resolver)
  local out = {}
  local i   = 1
  local n   = #tokens

  -- Default resolver: append .lua
  resolver = resolver or function(p)
    if p:match("%.lua$") then return p end
    return p .. ".lua"
  end

  while i <= n do
    local t = tokens[i]

    -- import "path" [as alias]
    if t.k==K.NAME and t.v=="import" then
      local p = i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end

      if tokens[p] and tokens[p].k==K.STRING then
        local rawPath = tokens[p].v
        -- strip quotes
        local path = rawPath:match('^"(.*)"$') or rawPath:match("^'(.*)'$") or rawPath
        p=p+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end

        -- optional  as alias
        -- Extract the basename (last path component) as the default alias
        local baseName = path:match("([^/\\]+)$") or path
        local alias = baseName:gsub("%.sua$",""):gsub("%.lua$","")
        if tokens[p] and tokens[p].k==K.NAME and tokens[p].v=="as" then
          p=p+1
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          if tokens[p] and tokens[p].k==K.NAME then
            alias = tokens[p].v
            p=p+1
          end
        end

        -- Resolve to .lua path and load header
        if not path or path == "" then
          out[#out+1] = t; i=i+1; goto continueImport
        end
        local luaPath = resolver(path)
        if not luaPath then
          out[#out+1] = t; i=i+1; goto continueImport
        end
        local exports = loadHeader(luaPath)
        if exports then
          Sua.importedModules[alias] = { exports=exports, path=luaPath }
        end

        -- Emit a safe dofile call that raises a clear error if the
        -- module returns nil (e.g. missing return statement, wrong path).
        -- Generated code:
        --   local alias = (function()
        --     local _m = dofile("luaPath")
        --     assert(_m ~= nil, "import: 'luaPath' returned nil")
        --     return _m
        --   end)()
        local ref = t
        local safeLoad = string.format(
          "(function()\nlocal _m = dofile(%q)\n" ..
          "assert(_m ~= nil, %q)\nreturn _m\nend)()",
          luaPath,
          "import: '" .. luaPath .. "' returned nil - did you compile with --emit-header?"
        )
        out[#out+1] = synth(K.KW,   "local",   ref)
        out[#out+1] = synth(K.SPACE, " ",       ref)
        out[#out+1] = synth(K.NAME,  alias,     ref)
        out[#out+1] = synth(K.SPACE, " ",       ref)
        out[#out+1] = synth(K.OP,    "=",       ref)
        out[#out+1] = synth(K.SPACE, " ",       ref)
        out[#out+1] = synth(K.RAW,   safeLoad,  ref)

        i = p
      else
        -- Not a valid import - pass through
        out[#out+1] = t; i=i+1
      end
      ::continueImport::
    else
      out[#out+1] = t; i=i+1
    end
  end
  return out
end

------------------------------------------------------------------------
-- PIPELINE
-- Ordered list of named stages. Options control debug/enable flags.
-- Returns final Lua source string.
------------------------------------------------------------------------

local function runPipeline(src, options)
  options = options or {}

  -- Stage 0: text pre-passes (must stay text -- tokenizer can't handle these)
  src = expandOneLiners(src)
  local stash
  src, stash = stripRawBlocks(src)
  src = stripDebugBlocks(src, options.debugNames)

  -- Stage 1: tokenize
  local tokens = tokenize(src)

  -- Stage 2: token passes (order matters)
  tokens = expandNamespaces(tokens) -- must run before expandStructs
  tokens = expandStructs(tokens)   -- must precede type-strip (needs field types)
  tokens = expandEnums(tokens)
  tokens = expandSwitch(tokens)
  tokens = expandDefines(tokens)
  tokens = expandImports(tokens, options and options.resolver)
  tokens = stripTypeAnnotations(tokens)
  tokens = expandKeywordSugar(tokens)

  -- Validate parenthesised conditions before brace transpilation
  local parenErr = checkParens(tokens)
  if parenErr then
    return nil, "Syntax error: " .. parenErr
  end

  tokens = transpileBraces(tokens)

  -- Stage 3: restore raw blocks
  tokens = restoreRawBlocks(tokens, stash)

  -- Stage 4: emit
  local result = emit(tokens)

  -- If module return is requested, append a return statement.
  -- Scan source for namespace declarations to find what to return.
  --
  -- Single namespace:    return <name>
  --   dofile() returns the namespace table directly.
  --   import "std" -> local std = <namespace table>
  --   std.Vec2:new() works.
  --
  -- Multiple namespaces: return { A=A, B=B, ... }
  --   dofile() returns a wrapper.
  --   import "lib" -> local lib = wrapper
  --   lib.A.foo() to access.
  if options.moduleReturn then
    local nsNames = {}
    local seen    = {}
    for name in src:gmatch("namespace%s+([%a_][%w_]*)%s*{") do
      if not seen[name] then seen[name]=true; nsNames[#nsNames+1]=name end
    end
    if #nsNames == 1 then
      -- Single namespace: return it directly
      result = result .. "\nreturn " .. nsNames[1] .. "\n"
    elseif #nsNames > 1 then
      -- Multiple namespaces: return wrapper table
      local parts = {}
      for _, name in ipairs(nsNames) do parts[#parts+1] = name .. " = " .. name end
      result = result .. "\nreturn { " .. table.concat(parts, ", ") .. " }\n"
    end
  end

  return result
end

------------------------------------------------------------------------
-- CHECKERS
-- Each checker takes the raw source and returns a list of warning strings.
-- They share a common setup: tokenize + scope analysis on clean source.
------------------------------------------------------------------------

-- Prepare a clean token stream and scope map for checking
-- (debug blocks stripped, but type annotations kept for analysis)
local function prepareForCheck(src)
  local clean = expandOneLiners(src)
  clean = stripDebugBlocks(clean, nil)  -- strip all debug blocks
  -- Strip raw blocks so their contents (which may contain arbitrary Lua,
  -- including bare `if x` without parens) don't trigger false paren errors.
  local _stash
  clean, _stash = stripRawBlocks(clean)
  local tokens = tokenize(clean)
  tokens = expandNamespaces(tokens)
  tokens = expandStructs(tokens)
  tokens = expandEnums(tokens)
  tokens = expandSwitch(tokens)
  tokens = expandImports(tokens)  -- loads headers into Sua.importedModules
  -- Run paren check so checkers bail early on invalid source
  local parenErr = checkParens(tokens)
  if parenErr then return nil, nil, nil, parenErr end
  local scopeMap = analyseScope(tokens)
  return tokens, scopeMap, clean
end

-- TYPE CHECKER
-- Warns on type mismatches in declarations, assignments, comparisons,
-- function return types, and switch cases.
local function typeCheck(src)
  local warnings = {}
  local tokens, scopeMap, clean, prepErr = prepareForCheck(src)
  if prepErr then return { "  [error]: " .. prepErr } end
  local n = #tokens

  local function warn(line, msg)
    warnings[#warnings+1] = "  [type] line " .. line .. ": " .. msg
  end

  -- Helper: resolve type of a NAME token using scope map
  local function typeOf(idx)
    local m = scopeMap[idx]
    return m and m.type or nil
  end

  -- Helper: are two type strings compatible?
  local function compat(a, b)
    if not a or not b then return true end
    a = resolveAlias(a); b = resolveAlias(b)
    if a==b then return true end
    if a=="any" or b=="any" then return true end
    local nums = {number=true}
    if nums[a] and nums[b] then return true end
    local strs = {string=true}
    if strs[a] and strs[b] then return true end
    if Sua.structs[a] and b=="table" then return true end
    if Sua.structs[b] and a=="table" then return true end
    return false
  end

  -- Helper: infer type of a literal token
  local function litType(t)
    if t.k==K.NUMBER  then return "number"  end
    if t.k==K.STRING  then return "string"  end
    if t.k==K.KW and (t.v=="true" or t.v=="false") then return "boolean" end
    if t.k==K.KW and t.v=="nil"  then return "nil"    end
    return nil
  end

  -- Walk tokens
  local i = 1

  -- Pre-collect function signatures (forward reference support)
  local funcSigs = {}
  do
    local j = 1
    while j <= n do
      local t = tokens[j]
      if t.k==K.KW and t.v=="function" then
        -- find name
        local p = j+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k==K.NAME then
          local fname = tokens[p].v
          -- find ->
          while p<=n and tokens[p].k~=K.RPAREN and tokens[p].k~=K.EOF do p=p+1 end
          if tokens[p] then p=p+1 end
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          if tokens[p] and tokens[p].k==K.OP and tokens[p].v=="->" then
            p=p+1
            while p<=n and tokens[p].k==K.SPACE do p=p+1 end
            if tokens[p] and tokens[p].k==K.NAME then
              funcSigs[fname] = resolveAlias(tokens[p].v)
            end
          end
        end
      end
      j=j+1
    end
  end

  -- Resolve type of a module.member expression starting at token p.
  -- Returns type string or nil.
  local function resolveImportedMember(p)
    local t = tokens[p]
    if not (t and t.k==K.NAME) then return nil end
    local mod = Sua.importedModules[t.v]
    if not mod then return nil end
    -- Expect  .member  or  .member(
    local p2=p+1
    while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
    if not (tokens[p2] and tokens[p2].k==K.DOT) then return nil end
    local p3=p2+1
    while p3<=n and tokens[p3].k==K.SPACE do p3=p3+1 end
    if not (tokens[p3] and tokens[p3].k==K.NAME) then return nil end
    local memberName = tokens[p3].v
    local exp = mod.exports[memberName]
    if not exp then return nil end
    if exp.kind=="function" then return exp.ret end
    if exp.kind=="var"      then return exp.type end
    if exp.kind=="struct"   then return memberName end
    return nil
  end

  -- Infer type of a token sequence starting at position p (single token)
  local function inferTok(p)
    local t = tokens[p]
    if not t then return nil end
    local lt = litType(t)
    if lt then return lt end
    if t.k==K.NAME then
      -- imported module.member
      local impType = resolveImportedMember(p)
      if impType then return impType end
      -- struct constructor: Name.new( or Name:new(
      local p2=p+1
      while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
      if tokens[p2] and (tokens[p2].k==K.DOT or tokens[p2].k==K.COLON) then
        local p3=p2+1
        while p3<=n and tokens[p3].k==K.SPACE do p3=p3+1 end
        if tokens[p3] and tokens[p3].k==K.NAME and tokens[p3].v=="new" then
          if Sua.structs[t.v] then return t.v end
        end
      end
      -- function call return type
      if tokens[p2] and tokens[p2].k==K.LPAREN then
        if funcSigs[t.v] then return funcSigs[t.v] end
      end
      -- scope type
      return typeOf(p)
    end
    return nil
  end

  while i <= n do
    local t = tokens[i]

    -- 1. Variable declaration:  local name = rhs
    --    (let was expanded to local; glet was stripped leaving bare assignment)
    if t.k==K.KW and t.v=="local" then
      -- find the name
      local p = i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.NAME then
        local nameIdx = p
        local declType = typeOf(nameIdx)
        -- find = sign
        while p<=n and not (tokens[p].k==K.OP and tokens[p].v=="=") and
              tokens[p].k~=K.NEWLINE and tokens[p].k~=K.EOF do p=p+1 end
        if tokens[p] and tokens[p].k==K.OP and tokens[p].v=="=" then
          local p2 = p+1
          while p2<=n and tokens[p2].k==K.SPACE do p2=p2+1 end
          local rhsType = inferTok(p2)
          if declType and rhsType and not compat(declType, rhsType) then
            warn(t.line, "'" .. tokens[nameIdx].v .. "' declared as " ..
                 declType .. " but assigned " .. rhsType)
          end
        end
      end

    -- 2. == and ~= comparisons: check type compatibility
    elseif t.k==K.OP and (t.v=="==" or t.v=="~=") then
      -- find LHS: walk back past spaces
      local lhsIdx = i-1
      while lhsIdx>=1 and tokens[lhsIdx].k==K.SPACE do lhsIdx=lhsIdx-1 end
      -- find RHS: walk forward past spaces
      local rhsIdx = i+1
      while rhsIdx<=n and tokens[rhsIdx].k==K.SPACE do rhsIdx=rhsIdx+1 end
      local lt = inferTok(lhsIdx)
      local rt = inferTok(rhsIdx)
      if lt and rt and not compat(lt, rt) then
        local lv = tokens[lhsIdx] and tokens[lhsIdx].v or "?"
        local rv = tokens[rhsIdx] and tokens[rhsIdx].v or "?"
        warn(t.line, "comparison '" .. lv .. " " .. t.v .. " " .. rv ..
             "' - left is " .. lt .. ", right is " .. rt ..
             " (always " .. (t.v=="~=" and "true" or "false") .. ")")
      end

    -- 3. local function with missing ->: warn
    elseif t.k==K.KW and t.v=="function" then
      -- check for bare 'local function' (should use plain function)
      local prev = i-1
      while prev>=1 and tokens[prev].k==K.SPACE do prev=prev-1 end
      if tokens[prev] and tokens[prev].k==K.KW and tokens[prev].v=="local" then
        local p=i+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k==K.NAME then
          warn(t.line, "use plain 'function " .. tokens[p].v ..
               "' (auto-local) instead of 'local function'")
        end
      end

    -- 4. Bare -> with no type
    elseif t.k==K.OP and t.v=="->" then
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if not (tokens[p] and tokens[p].k==K.NAME) then
        warn(t.line, "'->' with no return type - did you mean '->TypeName'?")
      end

    -- 5. Switch case type checking
    elseif t.k==K.KW and t.v=="switch" then
      -- find expression identifier
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      -- strip optional parens
      if tokens[p] and tokens[p].k==K.LPAREN then p=p+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      end
      local exprType = nil
      local exprName = ""
      if tokens[p] and tokens[p].k==K.NAME then
        exprType = typeOf(p)
        exprName = tokens[p].v
      end
      if exprType then
        -- scan ahead in tokens for case values
        local depth = 0
        local q = i+1
        while q<=n do
          if tokens[q].k==K.LBRACE then depth=depth+1
          elseif tokens[q].k==K.RBRACE then
            depth=depth-1; if depth<0 then break end
          elseif tokens[q].k==K.KW and tokens[q].v=="case" and depth==1 then
            -- collect case pattern tokens
            local q2 = q+1
            while q2<=n and tokens[q2].k==K.SPACE do q2=q2+1 end
            -- skip comparison and 'is' patterns
            local isComp  = tokens[q2] and tokens[q2].k==K.OP and
                            tokens[q2].v:match("^[<>~!]")
            local isIs    = tokens[q2] and tokens[q2].k==K.NAME and
                            tokens[q2].v=="is"
            if not isComp and not isIs then
              local vt = inferTok(q2)
              if vt and not compat(exprType, vt) then
                warn(tokens[q].line, "switch on '" .. exprName ..
                     "' (" .. exprType .. ") - case value is " .. vt ..
                     " (incompatible)")
              end
            end
          end
          q=q+1
        end
      end
    end

    i=i+1
  end

  return warnings
end

-- RETURN CHECKER
-- Warns when a typed function is missing a return on some path,
-- or returns the wrong type.
local function returnCheck(src)
  local warnings = {}
  local tokens, scopeMap, clean, prepErr = prepareForCheck(src)
  if prepErr then return { "  [error]: " .. prepErr } end
  local n = #tokens

  local function warn(line, msg)
    warnings[#warnings+1] = "  [return] line " .. line .. ": " .. msg
  end

  local function compat(a, b)
    if not a or not b then return true end
    a=resolveAlias(a); b=resolveAlias(b)
    if a==b or a=="any" or b=="any" then return true end
    return false
  end

  -- Collect function signatures: fname -> retType
  local funcSigs = {}
  do
    local j=1
    while j<=n do
      if tokens[j].k==K.KW and tokens[j].v=="function" then
        local p=j+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k==K.NAME then
          local fname=tokens[p].v
          while p<=n and tokens[p].k~=K.RPAREN and tokens[p].k~=K.EOF do p=p+1 end
          if tokens[p] then p=p+1 end
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          if tokens[p] and tokens[p].k==K.OP and tokens[p].v=="->" then
            p=p+1
            while p<=n and tokens[p].k==K.SPACE do p=p+1 end
            if tokens[p] and tokens[p].k==K.NAME then
              funcSigs[fname] = resolveAlias(tokens[p].v)
            end
          end
        end
      end
      j=j+1
    end
  end

  -- Infer type of a single token
  local function inferTok(p)
    local t=tokens[p]
    if not t then return nil end
    if t.k==K.NUMBER then return "number" end
    if t.k==K.STRING then return "string" end
    if t.k==K.KW and (t.v=="true" or t.v=="false") then return "boolean" end
    if t.k==K.KW and t.v=="nil" then return "nil" end
    if t.k==K.NAME then
      local m=scopeMap[p]
      if m then return m.type end
      if funcSigs[t.v] then return funcSigs[t.v] end
    end
    return nil
  end

  -- Walk token stream tracking function bodies
  local funcStack = {}   -- each: { name, retType, braceDepth, lineNum, hasReturn }
  local braceDepth = 0
  local i = 1

  while i <= n do
    local t = tokens[i]

    if t.k==K.LBRACE then
      braceDepth=braceDepth+1
      -- check if we just opened a function body
      if funcStack[#funcStack] and not funcStack[#funcStack].opened then
        funcStack[#funcStack].opened = true
        funcStack[#funcStack].braceDepth = braceDepth
        funcStack[#funcStack].hasReturn = false
      end

    elseif t.k==K.RBRACE then
      -- check if this closes a tracked function
      local fs = funcStack[#funcStack]
      if fs and fs.opened and braceDepth == fs.braceDepth then
        if not fs.hasReturn then
          warn(fs.lineNum, "function '" .. fs.name ..
               "' is typed as " .. fs.retType ..
               " but not all code paths return a value")
        end
        funcStack[#funcStack]=nil
      end
      braceDepth=braceDepth-1

    elseif t.k==K.KW and t.v=="function" then
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.NAME then
        local fname=tokens[p].v
        local fline=t.line
        while p<=n and tokens[p].k~=K.RPAREN and tokens[p].k~=K.EOF do p=p+1 end
        if tokens[p] then p=p+1 end
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        local retType=nil
        if tokens[p] and tokens[p].k==K.OP and tokens[p].v=="->" then
          p=p+1
          while p<=n and tokens[p].k==K.SPACE do p=p+1 end
          if tokens[p] and tokens[p].k==K.NAME then
            retType=resolveAlias(tokens[p].v)
          end
        end
        if retType then
          funcStack[#funcStack+1]={name=fname,retType=retType,lineNum=fline,opened=false}
        end
      end

    elseif t.k==K.KW and t.v=="return" then
      -- Check return value type
      local fs=funcStack[#funcStack]
      if fs and fs.opened then
        fs.hasReturn=true
        -- find return value
        local p=i+1
        while p<=n and tokens[p].k==K.SPACE do p=p+1 end
        if tokens[p] and tokens[p].k~=K.NEWLINE and tokens[p].k~=K.EOF then
          local retValType=inferTok(p)
          if retValType and not compat(fs.retType, retValType) then
            warn(t.line, "function '" .. fs.name .. "' returns " ..
                 fs.retType .. " but return value is " .. retValType)
          end
        end
      end
    end

    i=i+1
  end

  return warnings
end

-- DECLARATION CHECKER
-- Warns when identifiers are used without being declared in scope,
-- or when a bare assignment creates an implicit global.
local function declarationCheck(src)
  local warnings = {}
  local tokens, scopeMap, clean, prepErr = prepareForCheck(src)
  if prepErr then return { "  [error]: " .. prepErr } end
  local n = #tokens

  local function warn(line, msg)
    warnings[#warnings+1] = "  [decl] line " .. line .. ": " .. msg
  end

  local function isKnown(name)
    return Sua.knownGlobals[name] or Sua.structs[name] or Sua.importedModules[name]
  end

  -- Helper: is position p a type annotation NAME?
  -- A NAME is a type annotation if the nearest non-space token before it is a COLON
  -- or if it follows -> (return type)
  local function isTypeAnnotation(p)
    local prev = p - 1
    while prev >= 1 and tokens[prev].k == K.SPACE do prev = prev - 1 end
    if not tokens[prev] then return false end
    local pk = tokens[prev].k
    local pv = tokens[prev].v
    -- : TypeName  (parameter or variable annotation)
    if pk == K.COLON then return true end
    -- -> TypeName  (return type)
    if pk == K.OP and pv == "->" then return true end
    return false
  end

  local i = 1
  while i <= n do
    local t = tokens[i]

    -- Bare assignment to undeclared name: NAME = (not ==)
    if t.k==K.NAME then
      -- Skip type annotation names entirely
      if isTypeAnnotation(i) then i=i+1; goto dcNext end

      -- Find next meaningful token
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      local nxt = tokens[p]

      -- Find previous meaningful token
      local prev=i-1
      while prev>=1 and tokens[prev].k==K.SPACE do prev=prev-1 end
      local prevTok = tokens[prev]

      local m = scopeMap[i]
      local isDeclared = m and m.declared
      local known = isKnown(t.v) or LUA_KEYWORDS[t.v]

      -- Skip: field names after . or :, function name after 'function' keyword,
      -- struct/enum name after their keyword
      local isField    = prevTok and (prevTok.k==K.DOT or prevTok.k==K.COLON)
      local isFuncDecl = prevTok and prevTok.k==K.KW and prevTok.v=="function"
      local isKwDecl   = prevTok and prevTok.k==K.KW and
                         (prevTok.v=="struct" or prevTok.v=="enum")

      if not isField and not isFuncDecl and not isKwDecl and not known then
        local isAssign = nxt and nxt.k==K.OP and nxt.v=="="
        local isCompare = nxt and nxt.k==K.OP and (nxt.v=="==" or nxt.v=="~=")
        if isAssign and not isDeclared then
          -- Bare assignment to undeclared name = implicit global
          warn(t.line, "'" .. t.v ..
               "' assigned without declaration - use 'glet' for intentional globals")
        elseif not isAssign and not isDeclared then
          -- Used in expression but never declared
          warn(t.line, "'" .. t.v .. "' used but not declared in this scope")
        end
      end
    end
    ::dcNext::

    -- local without let: warn
    if t.k==K.KW and t.v=="local" then
      -- find what follows
      local p=i+1
      while p<=n and tokens[p].k==K.SPACE do p=p+1 end
      if tokens[p] and tokens[p].k==K.NAME then
        warn(t.line, "bare 'local " .. tokens[p].v ..
             "' - use 'let " .. tokens[p].v .. "' instead")
      end
    end

    i=i+1
  end

  return warnings
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function Sua.transpile(src, options)
  local result, err = runPipeline(src, options)
  return result, err
end

function Sua.check(src, options)
  options = options or {}
  local all  = {}
  local seen = {}
  local function add(warns)
    for _, w in ipairs(warns) do
      if not seen[w] then seen[w]=true; all[#all+1]=w end
    end
  end
  if options.tc or options["type-check"]        then add(typeCheck(src))        end
  if options.rc or options["return-check"]       then add(returnCheck(src))      end
  if options.dc or options["declaration-check"]  then add(declarationCheck(src)) end
  return all
end

Sua.typeCheck        = typeCheck
Sua.returnCheck      = returnCheck
Sua.declarationCheck = declarationCheck
Sua.tokenize         = tokenize
Sua.analyseScope     = analyseScope
Sua.generateHeader    = generateHeader
Sua.loadHeader        = loadHeader
Sua.expandImports     = expandImports
Sua.expandNamespaces  = expandNamespaces



local function printError(s)
  if _G.printError then _G.printError(s)
  else io.stderr:write(s.."\n") end
end

------------------------------------------------------------------------
-- CLI
------------------------------------------------------------------------

local function printWarnings(label, file, warns)
  if #warns > 0 then
    print(label .. " warnings in " .. file .. ":")
    for _, w in ipairs(warns) do print(w) end
    print("")
  else
    print("No " .. label:lower() .. " warnings.")
  end
end

local function main(args)
  args = args or {}
  local doTC      = false
  local doRC      = false
  local doDC      = false
  local debugNames = nil
  local filtered  = {}

  local emitHeader = false
  for _, a in ipairs(args) do
    if     a=="--type-check"        or a=="--tc" then doTC=true
    elseif a=="--return-check"      or a=="--rc" then doRC=true
    elseif a=="--declaration-check" or a=="--dc" then doDC=true
    elseif a=="--emit-header"                     then emitHeader=true
    elseif a=="--debug-all"                       then debugNames="__all__"
    elseif a:match("^%-%-debug=(.+)$") then
      local names=a:match("^%-%-debug=(.+)$")
      debugNames=debugNames or {}
      for name in (names..","):gmatch("([^,]+),") do debugNames[name]=true end
    else
      filtered[#filtered+1]=a
    end
  end
  args = filtered

  if #args < 1 then
    print("BraceLua 2 Transpiler")
    print("Usage: sua [flags] <input.sua> [output.lua]")
    print("  --type-check/--tc        Type checker")
    print("  --return-check/--rc      Return path checker")
    print("  --declaration-check/--dc Undeclared variable checker")
    print("  --emit-header            Prepend type header to output .lua")
    print("  --debug=n1,n2            Enable named debug blocks")
    print("  --debug-all              Enable all debug blocks")
    return
  end

  local infile  = args[1]
  local outfile = args[2]

  -- Guard against accidentally writing to a .sua file
  if outfile and outfile:match("%.sua$") then
    printError("Output file '" .. outfile .. "' looks like a BraceLua source file.")
    printError("Did you mean: sua [flags] <input.sua> <output.lua>")
    return
  end

  -- Warn if extra positional args were passed (common mistake)
  if args[3] then
    printError("Unexpected argument '" .. args[3] .. "' - only one input and one output file are accepted.")
    printError("To import a library, use:  import \"path/to/lib\"  inside your .sua file.")
    return
  end

  local src, rerr = readFile(infile)
  if not src then printError(rerr); return end

  if doTC then printWarnings("Type",        infile, typeCheck(src))        end
  if doRC then printWarnings("Return",      infile, returnCheck(src))      end
  if doDC then printWarnings("Declaration", infile, declarationCheck(src)) end

  local result, terr = Sua.transpile(src, {
    debugNames   = debugNames,
    moduleReturn = emitHeader,  -- append return{} when emitting a library
  })
  if not result then
    printError("Compilation halted: " .. tostring(terr))
    return
  end

  -- Prepend header if requested
  if emitHeader then
    local header = generateHeader(src, infile)
    result = header .. result
  end

  if outfile then
    local ok, werr = writeFile(outfile, result)
    if not ok then printError(werr); return end
    print("Written to "..outfile)
    if emitHeader then print("Header embedded in output.") end
  else
    print(result)
  end
end

local _args = {...}
if shell then main(_args)
elseif fs then if #_args>0 then main(_args) end
elseif arg and arg[0] then main(arg)
end

return Sua
