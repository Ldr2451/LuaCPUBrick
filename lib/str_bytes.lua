-- string.byte and string.char: the two that build something in a loop.
--
-- Split out of the piece that held len, sub, byte and char together.  A piece is
-- charged for its characters at boot, so a program that only ever takes a
-- substring was parsing 404 characters of loop it cannot call.  See
-- lib/str_index.lua for the measurement and the other half.
--
-- byte returns several values through `unpack`, so this piece needs the
-- table-list piece loaded first; libStrBytes is gated on it for that reason and
-- libTabList therefore has to come earlier in the concatenation.
string = string or {}
string.byte = function(s, i, j)
  i = i or 1
  j = j or i
  if i < 0 then i = #s + i + 1 end
  if j < 0 then j = #s + j + 1 end
  if i < 1 then i = 1 end
  if j > #s then j = #s end
  if i > j then return end
  if i == j then return _s(4, s, i - 1, 0) end
  local r = {}
  for k = i, j do r[#r + 1] = _s(4, s, k - 1, 0) end
  return unpack(r, 1, #r)
end
string.char = function(...)
  local r = ""
  for i = 1, select('#', ...) do r = r .. _s(5, "", select(i, ...), 0) end
  return r
end