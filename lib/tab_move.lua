-- table.move, WITHOUT table.pack.
--
-- table.pack is a constructor plus select and this is a gap-closing loop;
-- naming one must not parse the other -- the insert/remove split measured the
-- same shape.  pack is lib/tab_pack.lua now.
--
-- Nothing here needs another piece: the loop is plain opcodes.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/tab_move.lua LIB_tab_move --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
table = table or {}
table.move = function(a1, f, e, t, a2)
  a2 = a2 or a1
  if e >= f then
    if t > e or t <= f or a1 ~= a2 then
      for i = 0, e - f do a2[t + i] = a1[f + i] end
    else
      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end
    end
  end
  return a2
end
