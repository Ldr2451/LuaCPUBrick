-- ipairs and pairs: both are a function, a state, and a control value.
--
-- The control value is the part that is easy to get wrong and that the chip
-- implements in the CALL arm rather than here: a generic for calls the
-- iterator with the state and the control and stops on the first nil, and both
-- of these hand back `0`/`nil` so the first call starts at 1.  `pairs` says
-- `nil, nil` because PUC's next takes two arguments and the extra one is
-- ignored, not because it is missing.
function _ipairs_iter(t, i) i = i + 1 local v = t[i] if v ~= nil then return i, v end end
function ipairs(t) return _ipairs_iter, t, 0 end
function pairs(t) return next, t, nil, nil end