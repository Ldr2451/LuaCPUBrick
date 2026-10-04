-- string.len and string.sub.
--
-- Both take their string through luaL_checklstring, which converts a NUMBER and
-- refuses anything else, so string.len(999) is 3 and string.sub(12345, 2, 3) is "23".
-- Neither did: `#s` is an opcode with no coercion in front of it, so both raised
-- "attempt to get length of a number value" on a number and len({}) answered 0
-- silently where PUC refuses a table.
--
-- So the piece does what luaL_checklstring does.  In the piece rather than the gate:
-- piece text is a string constant, so this costs boot ticks and no nodes, and the
-- gate is shared with callers that already hold a string.  One `type` call per
-- invocation; the message is built only on the failing path.
string = string or {}
string.len = function(s)
local t = type(s)
if t == "number" then s = tostring(s)
elseif t ~= "string" then error("bad argument #1 to 'string.len' (string expected, got " .. t .. ")", 2) end
return #s
end
string.sub = function(s, i, j)
local t0 = type(s)
if t0 == "number" then s = tostring(s)
elseif t0 ~= "string" then error("bad argument #1 to 'string.sub' (string expected, got " .. t0 .. ")", 2) end
local l = #s
i = i or 1
j = j or -1
if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end
if j < 0 then j = l + j + 1 elseif j > l then j = l end
if i > j then return "" end
return _s(1, s, i - 1, j - i + 1)
end
