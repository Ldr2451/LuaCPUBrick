-- string.char, WITHOUT string.byte.  See lib/str_byte.lua for the split and the
-- measurement.
--
-- Each argument becomes one character through `_s(5, ...)`, so the accumulator
-- starts empty and the result is a concatenation of single-character pieces.
string = string or {}
string.char = function(...)
local r = ""
for i = 1, select('#', ...) do r = r .. _s(5, "", select(i, ...), 0) end
return r
end
