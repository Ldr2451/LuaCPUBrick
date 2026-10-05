-- string.find and string.match, over the _pat gate.
--
-- Both are the same matcher with a different result shape, so both are one
-- line over one gate, and both live in one piece because a program that
-- matches also usually finds.
--
-- THIS PIECE IS PAIRED WITH LIB_str_gsub and must not be installed twice.
-- `libStrGsub` returns `LIB_str_pat .. LIB_str_gsub`, so a `d ||` in front of
-- both gates emits the pattern piece twice and the library fails to PARSE --
-- which is the silent failure: every function in it stops answering, with no
-- message and no line.  That is why libStrPat stands down when `d` is set
-- rather than both being loaded independently.
string = string or {}
string.find = function(...) return _pat(0, ...) end
string.match = function(...) return _pat(1, ...) end