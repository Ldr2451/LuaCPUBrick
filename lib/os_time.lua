-- os.time, WITHOUT os.date's calendar.
--
-- os.date is five thousand characters of formatting civil-from-days, month and
-- weekday names; os.time is days_to_civil plus PUC's field validation.  A
-- program stamping epochs paid the whole calendar at boot -- the insert/remove
-- split measured the same shape.  os.date is lib/os_date.lua now.
--
-- The boundary is honest rather than convenient: os.time() with no argument
-- needs WALL time, and the chip has uptime (clock()) but no epoch -- so it
-- errors cleanly instead of answering from a clock that does not exist.
-- Everything here is arithmetic on an explicit table carried in, UTC (no OS
-- timezone exists on the chip).
--
-- dcivil rides along: days since 1970-01-01 (Howard Hinnant's days_from_civil),
-- exact for any year a double distinguishes.  All divisions are `//`, never
-- `/`: `/` tags float (and "2024.0" is not a year), while `//` on integers tags
-- int -- which is what every date field must be, because they end up
-- concatenated into strings.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/os_time.lua LIB_os_time --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
os = os or {}
local function dcivil(y, m, d)
  if m <= 2 then y, m = y - 1, m + 12 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m - 3) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
os.time = function(t)
  if t == nil then
    error("bad argument #1 to 'os.time' (no clock)", 2)
  end
  -- PUC checks the fields in order, each with its own message: a missing
  -- year, a non-integer one, and one no calendar holds.  Only the year has
  -- a range (month 13 and day 0 normalize); hour/min/sec default and are
  -- integers when given.
  local y, m, d = t.year, t.month, t.day
  if y == nil then
    error("field 'year' missing in date table", 2)
  end
  local iy = _m(13, y, 0)
  if iy == nil then
    error("field 'year' is not an integer", 2)
  end
  if iy < -2147483648 or iy > 2147483647 then
    error("field 'year' is out-of-bound", 2)
  end
  if m == nil then
    error("field 'month' missing in date table", 2)
  end
  if _m(13, m, 0) == nil then
    error("field 'month' is not an integer", 2)
  end
  if d == nil then
    error("field 'day' missing in date table", 2)
  end
  if _m(13, d, 0) == nil then
    error("field 'day' is not an integer", 2)
  end
  local h, mi, s = t.hour or 12, t.min or 0, t.sec or 0
  if _m(13, h, 0) == nil then
    error("field 'hour' is not an integer", 2)
  end
  if _m(13, mi, 0) == nil then
    error("field 'min' is not an integer", 2)
  end
  if _m(13, s, 0) == nil then
    error("field 'sec' is not an integer", 2)
  end
  local total = dcivil(y, m, d) * 86400 + h * 3600 + mi * 60 + s
  return _m(13, total, 0) or total
end
