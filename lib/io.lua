-- io.read / io.write / io.lines: the file half of PUC's io, as three functions.
--
-- The chip has one text channel (the log) and one input stream, both reached
-- through the _rd / _wr gates, so this is io's *shape* rather than io: `read`
-- with no argument means `*l` because there is nothing else to mean, and
-- `lines` hands back an iterator rather than a file handle, because there is
-- no handle to keep.  What PUC's own tests need from io -- read a line, read a
-- count, read the rest, write a list -- is all here.
--
-- io.stderr is NOT here: it is a piece of its own (lib/io_stderr.lua), and
-- naming one must not parse the other.
io = io or {}
io.read = function(...) if select('#', ...) == 0 then return _rd('*l') end return _rd((...)) end
io.write = function(...) for i = 1, select('#', ...) do _wr(tostring((select(i, ...)))) end end
_io_next = function() local l = _rd('*l') if l == nil then return nil end return l end
io.lines = function() _rd('*r') return _io_next end