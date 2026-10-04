-- io.stderr, PUC 5.5's shape.
--
-- PUC's stderr is a FILE* userdata and a separate stream from stdout.  The chip
-- has one text channel -- the log, which io.write already targets through _wr
-- -- so this is a table with the write half of the file methods, and both
-- streams land in the same place.  That merge is the documented divergence: a
-- program that separates its diagnostics from its output cannot do it here.
-- What it CAN do is everything PUC's own tests do with stderr (tracegc's
-- progress dots are io.stderr:write), and the `:` call passes self, which is
-- why write returns it.  flush exists because programs call it; there is
-- nothing to flush to.  The rest of the file methods (read, lines, seek,
-- close) are absent, and calling one is "attempt to call", not silence.
io = io or {}
io.stderr = {
  write = function(self, ...)
    for i = 1, select("#", ...) do _wr(tostring((select(i, ...)))) end
    return self
  end,
  flush = function(self) return self end,
}
