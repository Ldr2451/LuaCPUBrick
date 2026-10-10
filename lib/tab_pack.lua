-- table.pack, WITHOUT table.move.
--
-- table.move is a gap-closing loop and this is a constructor plus select; naming
-- one must not parse the other -- the insert/remove split measured the same
-- shape.  move is lib/tab_move.lua now.
--
-- Nothing here needs another piece: select is a gate, so the vararg walk needs
-- nothing else.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/tab_pack.lua LIB_tab_pack --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
table = table or {}
table.pack = function(...) local t = {...} t.n = select('#', ...) return t end
