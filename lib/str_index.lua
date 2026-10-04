-- string.len and string.sub: the two a program reaches for in every loop.
--
-- Split out of the piece that used to hold len, sub, byte and char together,
-- because a piece is charged for its CHARACTERS at boot and byte/char are the
-- two that build a table with a loop.  A program that only ever takes a
-- substring was measured paying 1,094 ticks of boot for a group where 420 of the
-- 838 characters were unreachable for it; this file is 434 of them.
--
-- Neither of these needs the table library or unpack, which is what makes the
-- split clean: string.byte used `unpack(r, 1, #r)`, so a program that called
-- byte also dragged in the table-list piece whether it wanted it or not.
string = string or {}
string.len = function(s) return #s end
string.sub = function(s, i, j)
  local l = #s
  i = i or 1
  j = j or -1
  if i < 0 then i = l + i + 1 if i < 1 then i = 1 end elseif i == 0 then i = 1 end
  if j < 0 then j = l + j + 1 elseif j > l then j = l end
  if i > j then return "" end
  return _s(1, s, i - 1, j - i + 1)
end