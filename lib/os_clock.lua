-- os.clock/difftime/setlocale: the clock piece, WITHOUT the calendar.
--
-- Split from os_date.lua because a program that times itself with clock()
-- must not parse 5,000 characters of calendar and validation to do it
-- (measured: naming os.clock loaded the whole date piece at boot).
-- difftime is one subtraction and setlocale is two comparisons; none of the
-- three needs dcivil, civil, parts or any validation.
os = os or {}
os.clock = function() return clock() + 0.0 end
os.difftime = function(a, b) return a - b + 0.0 end
os.setlocale = function(a, b)
if a == nil or a == "C" then return "C" end
return nil
end
