-- BraceLua Transpiler
-- Compiles BraceLua (brace-syntax Lua) to standard Lua
-- Compatible with ComputerCraft (Lua 5.1, no io/os file libs assumed)
--
-- BraceLua syntax:
--   if cond { ... }           -> if cond then ... end
--   elseif cond { ... }       -> elseif cond then ... end
--   else { ... }              -> else ... end
--   while cond { ... }        -> while cond do ... end
--   for ... { ... }           -> for ... do ... end
--   do { ... }                -> do ... end
--   repeat { ... } until cond -> repeat ... until cond
--   function f(...) { ... }   -> function f(...) ... end
--   function(...) { ... }     -> function(...) ... end
--   local function f() { }    -> local function f() ... end
--
-- Variable sugar:
--   let x = y       -> local x = y
--   glet x = y      -> x = y              (global, no "local")
--
-- Function locality:
--   function f() {} -> local function f() ... end  (local by default)
--   global function f() {} -> function f() ... end  (explicit global)
--
-- Operator sugar:
--   x++     -> x = x + 1       x--    -> x = x - 1
--   x += y  -> x = x + y       x -= y -> x = x - y
--   x *= y  -> x = x * y       x /= y -> x = x / y
--   x //= y -> x = x // y      x %= y -> x = x % y
--   x ^= y  -> x = x ^ y       x ..= y -> x = x .. y
--
-- Preprocessor:
--   define NAME value    -> replaces every occurrence of NAME with value
--   define NAME          -> replaces NAME with nothing (empty string)
--   (define lines are stripped from output entirely)
--
-- Enums:
--   enum Name { A, B, C }  -> local Name = { A=1, B=2, C=3 }
--   global enum Name { A } -> Name = { A=1 }        (no local)
--
-- Raw Lua insertion:
--   $[ ...lua code... ]$  -> passed through to output completely untouched
--
-- Tables still use {} as normal -- the transpiler is context-aware.
--
-- Usage (as a library):
--   local BraceLua = require("bracelua")
--   local result, err = BraceLua.transpile(source_string)
--   if err then print("Error: " .. err) else print(result) end
--
-- Usage (CC command):
--   bracelua <input.blua> [output.lua]

local BraceLua = {}

------------------------------------------------------------------------
-- Tokenizer
------------------------------------------------------------------------

local KEYWORDS = {
  ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true,
  ["let"]=true, ["glet"]=true,
  ["elseif"]=true, ["end"]=true, ["false"]=true, ["for"]=true,
  ["function"]=true, ["goto"]=true, ["if"]=true, ["in"]=true,
  ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
  ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
  ["until"]=true, ["while"]=true,
}

local TK = {
  KEYWORD   = "KEYWORD",
  IDENT     = "IDENT",
  NUMBER    = "NUMBER",
  STRING    = "STRING",
  LBRACE    = "LBRACE",
  RBRACE    = "RBRACE",
  LPAREN    = "LPAREN",
  RPAREN    = "RPAREN",
  LBRACKET  = "LBRACKET",
  RBRACKET  = "RBRACKET",
  COMMA     = "COMMA",
  SEMICOLON = "SEMICOLON",
  COLON     = "COLON",
  DOT       = "DOT",
  DOTDOT    = "DOTDOT",
  DOTDOTDOT = "DOTDOTDOT",
  EQ        = "EQ",
  OP        = "OP",
  COMMENT   = "COMMENT",
  SPACE     = "SPACE",
  NEWLINE   = "NEWLINE",
  EOF       = "EOF",
}

local function tokenize(src)
  -- Pre-pass: rewrite `x--` decrement to `x __DEC__` so `--` isn't eaten
  -- as a Lua comment.  We only replace `--` that immediately follows an
  -- lvalue-ending character ([a-zA-Z0-9_]  or  )  or  ]) with no space.
  -- We must NOT touch `--` inside strings or existing comments; a simple
  -- pattern pass is safe here because those contexts don't contain bare
  -- identifier/paren chars right before `--` at the token boundary.
  src = src:gsub("([%w_%]%)])(%-%-)", function(lv, _)
    return lv .. " __DEC__"
  end)

  local tokens = {}
  local i = 1
  local len = #src

  local function peek(offset)
    offset = offset or 0
    return src:sub(i + offset, i + offset)
  end

  local function advance()
    local ch = src:sub(i, i)
    i = i + 1
    return ch
  end

  local function matches(str)
    return src:sub(i, i + #str - 1) == str
  end

  while i <= len do
    local start = i
    local ch = peek()

    -- Spaces / tabs / carriage return
    if ch == ' ' or ch == '\t' or ch == '\r' then
      local sp = ""
      while i <= len and (peek() == ' ' or peek() == '\t' or peek() == '\r') do
        sp = sp .. advance()
      end
      tokens[#tokens+1] = { type=TK.SPACE, value=sp }

    -- Newlines
    elseif ch == '\n' then
      advance()
      tokens[#tokens+1] = { type=TK.NEWLINE, value='\n' }

    -- Long strings:  [=*[ ... ]=*]
    elseif ch == '[' and (peek(1) == '[' or peek(1) == '=') then
      local level = 0
      local j = i + 1
      while j <= len and src:sub(j,j) == '=' do level = level + 1; j = j + 1 end
      if src:sub(j,j) == '[' then
        i = j + 1
        local close = ']' .. string.rep('=', level) .. ']'
        local e = src:find(close, i, true)
        if not e then return nil, "Unterminated long string at pos " .. start end
        local value = src:sub(start, e + #close - 1)
        i = e + #close
        tokens[#tokens+1] = { type=TK.STRING, value=value }
      else
        advance()
        tokens[#tokens+1] = { type=TK.LBRACKET, value='[' }
      end

    -- Comments  --
    elseif ch == '-' and peek(1) == '-' then
      i = i + 2
      if peek() == '[' then
        local level = 0
        local j = i + 1
        while j <= len and src:sub(j,j) == '=' do level = level + 1; j = j + 1 end
        if src:sub(j,j) == '[' then
          i = j + 1
          local close = ']' .. string.rep('=', level) .. ']'
          local e = src:find(close, i, true)
          if not e then return nil, "Unterminated long comment at pos " .. start end
          local value = src:sub(start, e + #close - 1)
          i = e + #close
          tokens[#tokens+1] = { type=TK.COMMENT, value=value }
        else
          local nl = src:find('\n', i, true)
          local value
          if nl then value = src:sub(start, nl-1); i = nl
          else value = src:sub(start); i = len + 1 end
          tokens[#tokens+1] = { type=TK.COMMENT, value=value }
        end
      else
        local nl = src:find('\n', i, true)
        local value
        if nl then value = src:sub(start, nl-1); i = nl
        else value = src:sub(start); i = len + 1 end
        tokens[#tokens+1] = { type=TK.COMMENT, value=value }
      end

    -- Strings  ' or "
    elseif ch == '"' or ch == "'" then
      local quote = advance()
      local str = quote
      while i <= len and peek() ~= quote do
        if peek() == '\\' then str = str .. advance() end
        if i <= len then str = str .. advance() end
      end
      if i <= len then str = str .. advance() end
      tokens[#tokens+1] = { type=TK.STRING, value=str }

    -- Numbers
    elseif ch:match('%d') or (ch == '.' and peek(1):match('%d')) then
      local num = ""
      if peek() == '0' and (peek(1) == 'x' or peek(1) == 'X') then
        num = num .. advance() .. advance()
        while i <= len and peek():match('[0-9a-fA-F]') do num = num .. advance() end
      else
        while i <= len and peek():match('%d') do num = num .. advance() end
        if i <= len and peek() == '.' then
          num = num .. advance()
          while i <= len and peek():match('%d') do num = num .. advance() end
        end
        if i <= len and (peek() == 'e' or peek() == 'E') then
          num = num .. advance()
          if i <= len and (peek() == '+' or peek() == '-') then num = num .. advance() end
          while i <= len and peek():match('%d') do num = num .. advance() end
        end
      end
      tokens[#tokens+1] = { type=TK.NUMBER, value=num }

    -- Identifiers / keywords
    elseif ch:match('[a-zA-Z_]') then
      local id = ""
      while i <= len and peek():match('[a-zA-Z0-9_]') do id = id .. advance() end
      local ttype = KEYWORDS[id] and TK.KEYWORD or TK.IDENT
      tokens[#tokens+1] = { type=ttype, value=id }

    -- Braces & brackets
    elseif ch == '{' then advance(); tokens[#tokens+1] = { type=TK.LBRACE,    value='{' }
    elseif ch == '}' then advance(); tokens[#tokens+1] = { type=TK.RBRACE,    value='}' }
    elseif ch == '(' then advance(); tokens[#tokens+1] = { type=TK.LPAREN,    value='(' }
    elseif ch == ')' then advance(); tokens[#tokens+1] = { type=TK.RPAREN,    value=')' }
    elseif ch == '[' then advance(); tokens[#tokens+1] = { type=TK.LBRACKET,  value='[' }
    elseif ch == ']' then advance(); tokens[#tokens+1] = { type=TK.RBRACKET,  value=']' }
    elseif ch == ',' then advance(); tokens[#tokens+1] = { type=TK.COMMA,     value=',' }
    elseif ch == ';' then advance(); tokens[#tokens+1] = { type=TK.SEMICOLON, value=';' }

    -- Dots
    elseif ch == '.' then
      if matches("...") then i=i+3; tokens[#tokens+1] = { type=TK.DOTDOTDOT, value="..." }
      elseif src:sub(i,i+2) == "..=" then i=i+3; tokens[#tokens+1] = { type=TK.OP, value="..=" }
      elseif matches('..') then i=i+2; tokens[#tokens+1] = { type=TK.DOTDOT,    value='..' }
      else advance();               tokens[#tokens+1] = { type=TK.DOT,       value='.' }
      end

    -- Colon / label ::
    elseif ch == ':' then
      if matches('::') then i=i+2; tokens[#tokens+1] = { type=TK.OP,    value='::' }
      else advance();               tokens[#tokens+1] = { type=TK.COLON, value=':' }
      end

    -- = / ==
    elseif ch == '=' then
      if matches('==') then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='==' }
      else advance();               tokens[#tokens+1] = { type=TK.EQ, value='=' }
      end

    -- Increment / decrement
    elseif ch == '+' and peek(1) == '+' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='++' }
    elseif ch == '-' and peek(1) == '-' then
      -- careful: -- starts a Lua comment, already handled above, so this is unreachable
      -- but guard anyway
      i=i+2; tokens[#tokens+1] = { type=TK.OP, value='--_dec' }

    -- Compound assignment
    elseif ch == '+' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='+=' }
    elseif ch == '-' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='-=' }
    elseif ch == '*' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='*=' }
    elseif ch == '/' and peek(1) == '/' and src:sub(i+2,i+2) == '=' then
      i=i+3; tokens[#tokens+1] = { type=TK.OP, value='//=' }
    elseif ch == '/' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='/=' }
    elseif ch == '%' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='%=' }
    elseif ch == '^' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='^=' }

    -- Two-char operators
    elseif ch == '~' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='~=' }
    elseif ch == '<' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='<=' }
    elseif ch == '<' and peek(1) == '<' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='<<' }
    elseif ch == '>' and peek(1) == '=' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='>=' }
    elseif ch == '>' and peek(1) == '>' then i=i+2; tokens[#tokens+1] = { type=TK.OP, value='>>' }

    else
      advance()
      tokens[#tokens+1] = { type=TK.OP, value=ch }
    end
  end

  tokens[#tokens+1] = { type=TK.EOF, value='' }
  return tokens
end

------------------------------------------------------------------------
-- Transpiler
------------------------------------------------------------------------
--
-- Single-pass token rewriter.
--
-- `pending` tracks what keyword (then/do/nothing) should replace the
-- next { if it turns out to be a block opener.
--
-- A { is a block opener when `pending` is set AND the previous
-- meaningful token is one that can end a block head:
--   )  - end of condition / parameter list
--   keyword else/repeat/do - bare block starters
--
-- Everything else is a table constructor and passes through unchanged.
--
-- blockStack entries: { depth=N, closeWord=string, isRepeat=bool }
-- braceDepth counts ALL { } so we can match closing } to the right frame.

local function transpile(src)
  -- Raw Lua pass: extract $[...]$ blocks before anything else, replace with
  -- a unique placeholder, then re-insert verbatim after all other processing.
  local rawBlocks = {}
  local rawIndex = 0
  src = src:gsub("%$%[(.-)%]%$", function(code)
    rawIndex = rawIndex + 1
    local placeholder = "__RAWLUA_" .. rawIndex .. "__"
    rawBlocks[placeholder] = code
    return placeholder
  end)

  -- Preprocessor: scan for `define NAME value` lines before tokenizing.
  -- These lines are removed from the source and the NAME is substituted
  -- everywhere else as a whole-word replacement.
  local defines = {}
  local defineOrder = {}  -- preserve insertion order for longest-match priority

  -- Strip define lines and collect mappings
  src = src:gsub("([^\n]*)define%s+([%a_][%w_]*)([^\n]*)\n?", function(pre, name, rest)
    -- Only treat as a preprocessor directive if `define` appears at the
    -- start of the (trimmed) line, not inside expressions.
    if pre:match("^%s*$") then
      local value = rest:match("^%s*(.-)%s*$")  -- trim whitespace
      if not defines[name] then
        defineOrder[#defineOrder+1] = name
      end
      defines[name] = value
      return ""   -- strip the define line from source
    end
    -- Not a directive line; put it back unchanged
    return pre .. "define " .. name .. rest .. "\n"
  end)

  -- Sort by descending length so longer names match before shorter ones
  -- (e.g. MAX_SIZE before MAX)
  table.sort(defineOrder, function(a, b) return #a > #b end)

  -- Substitute: replace whole-word occurrences of each name.
  -- We must NOT replace inside strings or comments; since those are opaque
  -- at this stage, we use a word-boundary pattern (%f) which is safe for
  -- the vast majority of cases and consistent with C-style #define behaviour.
  if #defineOrder > 0 then
    for _, name in ipairs(defineOrder) do
      local value = defines[name]
      -- %f[%w_] / %f[^%w_] are Lua frontier patterns acting as word boundaries
      src = src:gsub("%f[%a_]" .. name .. "%f[^%w_]", value)
    end
  end

  -- Enum pre-pass: expand  [global] enum NAME { item, ... }
  -- into  [local] NAME = { item=1, item=2, ... }
  -- Supports optional trailing comma, arbitrary whitespace/newlines inside {}.
  -- NOTE: Lua patterns do not support optional groups `(...)?`, so we run
  -- two passes: one for `global enum` and one for bare `enum`.
  local function expandEnum(isglobal, name, body)
    local items = {}
    for item in body:gmatch("[%a_][%w_]*") do
      items[#items+1] = item
    end
    local fields = {}
    for i, item in ipairs(items) do
      fields[#fields+1] = item .. "=" .. i
    end
    local inner = table.concat(fields, ", ")
    local prefix = isglobal and "" or "local "
    return prefix .. name .. " = {" .. inner .. "}"
  end

  -- Pass 1: global enum NAME { ... }
  src = src:gsub(
    "global%s+enum%s+([%a_][%w_]*)%s*{([^}]*)}",
    function(name, body) return expandEnum(true, name, body) end
  )
  -- Pass 2: bare enum NAME { ... }  (not preceded by global — already handled)
  src = src:gsub(
    "enum%s+([%a_][%w_]*)%s*{([^}]*)}",
    function(name, body) return expandEnum(false, name, body) end
  )

  local tokens, err = tokenize(src)
  if not tokens then return nil, err end

  local out = {}
  local n = #tokens

  local pending = nil          -- "then" | "do" | "function" | "else" | "repeat" | "do_block" | nil
  local lastMeaningful = nil   -- last non-whitespace/comment token
  local braceDepth = 0
  local blockStack = {}

  local function isBlockOpen()
    if not pending then return false end
    if not lastMeaningful then return false end
    local lm = lastMeaningful
    if lm.type == TK.RPAREN then return true end
    if lm.type == TK.KEYWORD and
       (lm.value == 'else' or lm.value == 'repeat' or lm.value == 'do') then
      return true
    end
    return false
  end

  local function emit(s) out[#out+1] = s end

  for idx = 1, n do
    local tok = tokens[idx]

    if tok.type == TK.SPACE or tok.type == TK.NEWLINE or tok.type == TK.COMMENT then
      emit(tok.value)

    elseif tok.type == TK.EOF then
      -- done

    elseif tok.type == TK.LBRACE then
      if isBlockOpen() then
        braceDepth = braceDepth + 1
        local opener   = ""
        local isRepeat = false

        if     pending == "then"     then opener = "then"
        elseif pending == "do"       then opener = "do"
        elseif pending == "do_block" then opener = "do"
        elseif pending == "function" then opener = ""
        elseif pending == "else"     then opener = ""
        elseif pending == "repeat"   then opener = ""; isRepeat = true
        end

        blockStack[#blockStack+1] = { depth=braceDepth, closeWord="end", isRepeat=isRepeat }
        pending = nil

        -- Replace { with the opener keyword (or nothing for else/function/repeat)
        if opener ~= "" then emit(opener) end
        lastMeaningful = tok
      else
        -- Table constructor
        braceDepth = braceDepth + 1
        pending = nil
        emit('{')
        lastMeaningful = tok
      end

    elseif tok.type == TK.RBRACE then
      if #blockStack > 0 and blockStack[#blockStack].depth == braceDepth then
        local frame = table.remove(blockStack)
        braceDepth = braceDepth - 1
        if not frame.isRepeat then
          emit(frame.closeWord)   -- emit "end"
        end
        -- For repeat blocks the } is dropped; `until <cond>` follows naturally
        lastMeaningful = tok
      else
        braceDepth = braceDepth - 1
        emit('}')
        lastMeaningful = tok
      end

    elseif tok.type == TK.KEYWORD then
      local v = tok.value
      if     v == 'if' or v == 'elseif'  then pending = 'then'
      elseif v == 'while' or v == 'for'  then pending = 'do'
      elseif v == 'function' then
        pending = 'function'
        -- Auto-local: prepend `local` unless preceded by local/let/global/glet
        local preceded = lastMeaningful and lastMeaningful.value
        local alreadyScoped = (preceded == 'local' or preceded == 'let'
                               or preceded == 'global' or preceded == 'glet')
        if not alreadyScoped then
          emit('local ')
        end
      elseif v == 'else'                 then pending = 'else'
      elseif v == 'repeat'               then pending = 'repeat'
      elseif v == 'do'                   then pending = 'do_block'
      elseif v == 'local'                then -- keep existing pending (for `local function`)
      elseif v == 'let'                  then -- like local, keep pending for `let function`
      elseif v == 'glet'                 then pending = nil  -- global, emits nothing
      else                                    pending = nil
      end
      -- let -> local,  glet -> nothing (global assignment)
      if     v == 'let'  then emit('local')
      elseif v == 'glet' then -- emit nothing
      else                    emit(v)
      end
      lastMeaningful = tok

    elseif tok.type == TK.IDENT and tok.value == '__DEC__' then
      -- x-- desugared: replace `x __DEC__` with `x = x - 1`
      -- lastMeaningful holds the lvalue token; we need to find its full text.
      -- Because lvalues can be complex (a.b.c, a[i]) we captured everything
      -- emitted since the last statement start. Instead we use the simpler
      -- approach: grab the lvalue from the output buffer up to the last
      -- newline / semicolon / keyword boundary.
      -- Walk out[] backwards to collect the lvalue expression.
      local lval_parts = {}
      local j = #out
      -- skip trailing spaces
      while j >= 1 and out[j]:match("^%s+$") do j = j - 1 end
      -- collect tokens that form the lvalue (idents, dots, brackets, parens, colons)
      while j >= 1 do
        local part = out[j]
        -- stop at statement boundaries
        if part == "\n" or part == ";" then break end
        -- stop at keywords that cannot be part of an lvalue
        if part:match("^%a+$") and KEYWORDS[part] and
           part ~= "and" and part ~= "or" and part ~= "not" then break end
        table.insert(lval_parts, 1, part)
        j = j - 1
      end
      local lval = table.concat(lval_parts):match("^%s*(.-)%s*$")
      emit(" = " .. lval .. " - 1")
      lastMeaningful = tok

    elseif tok.type == TK.OP and tok.value == '++' then
      -- x++: lvalue already emitted; append `= lval + 1`
      local lval_parts = {}
      local j = #out
      while j >= 1 and out[j]:match("^%s+$") do j = j - 1 end
      while j >= 1 do
        local part = out[j]
        if part == "\n" or part == ";" then break end
        if part:match("^%a+$") and KEYWORDS[part] and
           part ~= "and" and part ~= "or" and part ~= "not" then break end
        table.insert(lval_parts, 1, part)
        j = j - 1
      end
      local lval = table.concat(lval_parts):match("^%s*(.-)%s*$")
      emit(" = " .. lval .. " + 1")
      lastMeaningful = tok

    elseif tok.type == TK.OP and (
        tok.value == '+='  or tok.value == '-='  or tok.value == '*='  or
        tok.value == '/='  or tok.value == '//=' or tok.value == '%='  or
        tok.value == '^='  or tok.value == '..=' ) then
      -- Compound assignment: lvalue op= rhs  ->  lvalue = lvalue op rhs
      -- Map operator
      local opmap = {
        ['+=']='+',['-=']='-',['*=']='*',['/=']='/',
        ['//=']='//',['%=']='%',['^=']='^',['..=']='..'
      }
      local op = opmap[tok.value]
      -- Collect lvalue from output buffer
      local lval_parts = {}
      local j = #out
      while j >= 1 and out[j]:match("^%s+$") do j = j - 1 end
      while j >= 1 do
        local part = out[j]
        if part == "\n" or part == ";" then break end
        if part:match("^%a+$") and KEYWORDS[part] and
           part ~= "and" and part ~= "or" and part ~= "not" then break end
        table.insert(lval_parts, 1, part)
        j = j - 1
      end
      local lval = table.concat(lval_parts):match("^%s*(.-)%s*$")
      -- Emit `= lval op ` and let the rhs tokens follow naturally
      emit(" = " .. lval .. " " .. op .. " ")
      lastMeaningful = tok

    else
      -- Reset pending only on semicolons; leave it alive through expressions
      if tok.type == TK.SEMICOLON then pending = nil end
      -- `global` before `function`: swallow it silently; the function handler
      -- checks lastMeaningful.value == 'global' to skip auto-local.
      if tok.type == TK.IDENT and tok.value == 'global' then
        lastMeaningful = tok  -- record it but don't emit
      else
        emit(tok.value)
        lastMeaningful = tok
      end
    end
  end

  if #blockStack > 0 then
    return nil, "Unclosed block brace — missing } somewhere"
  end

  local result = table.concat(out)

  -- Re-insert raw Lua blocks
  for placeholder, code in pairs(rawBlocks) do
    result = result:gsub(placeholder, function() return code end)
  end

  return result
end

BraceLua.transpile = transpile

------------------------------------------------------------------------
-- File I/O helpers  (CC fs API with fallback to standard io)
------------------------------------------------------------------------

local function resolvePath(path)
  -- In CC, shell.resolve turns relative paths into absolute ones
  -- based on the current working directory (e.g. "test.blua" -> "/test.blua")
  if shell then
    return shell.resolve(path)
  end
  return path
end

local function readFile(path)
  if fs then
    -- ComputerCraft
    local resolved = resolvePath(path)
    if not fs.exists(resolved) then
      return nil, "File not found: " .. resolved
    end
    local f = fs.open(resolved, "r")
    if not f then
      return nil, "Cannot open: " .. resolved
    end
    local src = f.readAll()
    f.close()
    return src
  else
    -- Standard Lua
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local src = f:read("*a")
    f:close()
    return src
  end
end

local function writeFile(path, content)
  if fs then
    -- ComputerCraft
    local resolved = resolvePath(path)
    local f = fs.open(resolved, "w")
    if not f then
      return false, "Cannot write: " .. resolved
    end
    f.write(content)
    f.close()
    return true
  else
    -- Standard Lua
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
  end
end

------------------------------------------------------------------------
-- CLI / CC entry point
------------------------------------------------------------------------

local function main(args)
  args = args or {}
  if #args < 1 then
    print("BraceLua Transpiler")
    print("Usage: bracelua <input.blua> [output.lua]")
    print("If output is omitted, result is printed to screen.")
    return
  end

  local infile  = args[1]
  local outfile = args[2]

  local src, rerr = readFile(infile)
  if not src then
    printError(rerr)
    return
  end

  local result, terr = BraceLua.transpile(src)
  if not result then
    printError("Transpile error: " .. tostring(terr))
    return
  end

  if outfile then
    local ok, werr = writeFile(outfile, result)
    if not ok then printError(werr); return end
    print("Written to " .. outfile)
  else
    print(result)
  end
end

-- ComputerCraft: shell global exists; standard Lua: arg table
if shell then
  main({ ... })
elseif arg and arg[0] then
  main(arg)
end

return BraceLua
