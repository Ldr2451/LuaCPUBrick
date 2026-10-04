-- unpack is a GATE, so this alias is the whole piece.
--
-- It used to sit at the head of LIB_tab_list with table.pack and table.move, and
-- naming table.unpack cost 460 ticks of boot to parse two functions it never
-- calls (measured, tools/chip/libcost.py).  unpack itself needs nothing, so an
-- alias for it should cost an alias.
--
-- Nothing here needs another piece: `unpack` is a gate, so it exists before any
-- piece text is spliced and the order of concatenation does not matter.
table = table or {}
table.unpack = unpack
