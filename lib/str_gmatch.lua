-- string.gmatch, bound to the _gmatch gate.
--
-- The iterator is a gate and not a piece because it is a MACHINE: it has to
-- suspend mid-match and resume, and a gate answers through the micro-step
-- (nxMode 3), one statement-level step per call.  So gmatch is two gates plus a
-- micro-step, and lib/gmatch.lua
-- is the PUC-verified Lua kept as the reference implementation the gates are
-- proved against -- deliberately not installed.
--
-- Measured, and the reason is not the node count: as a piece this was 2,970
-- ticks of boot against the gates' 1,053 nodes, because a piece drags in
-- string.find, string.sub, table.pack and table.unpack, and each of those
-- drags in another.  A piece is viable when everything it needs is already a
-- gate; this one does not qualify.
string = string or {}
string.gmatch = _gmatch