-- os.getenv: this host exposes no environment to the chip, so
-- the chip's environment IS empty and every variable is unset.
-- getenv therefore answers nil for everything -- PUC's own
-- answer for an unset variable, and the only answer this host
-- can give.  A program's os.getenv("X") or default idiom
-- therefore takes its default branch instead of crashing on a
-- missing function.  The one case that differs from PUC is a
-- variable the host has set: PUC answers its value, the chip
-- answers nil -- a documented boundary (an empty environment),
-- not a wrong answer, because nil is getenv's own "not there"
-- result and is what the program already handles.
--
-- PUC stringifies any non-nil argument and looks it up, so a
-- number answers nil too.  The two error cases are PUC's own
-- and need telling apart: NO argument says "got no value", an
-- explicit nil says "got nil" -- which is why the argument is
-- taken as a vararg, so select('#', ...) counts what was
-- actually passed.
os = os or {}
os.getenv = function(...)
  if select('#', ...) == 0 then
    error("bad argument #1 to 'os.getenv' (string expected, "
          .. "got no value)", 2)
  end
  local name = ...
  if name == nil then
    error("bad argument #1 to 'os.getenv' (string expected, "
          .. "got nil)", 2)
  end
  return nil
end
