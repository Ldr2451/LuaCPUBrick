-- os.date: the calendar piece, WITHOUT os.time.
--
-- os.time is days_to_civil plus field validation and lives in lib/os_time.lua:
-- a program stamping epochs must not parse five thousand characters of
-- formatting to do it.  What stays here needs civil (os.date) or both (the
-- yday line), plus PUC's field validation.
--
-- The boundary is honest rather than convenient: os.date() with no time needs
-- WALL time, and the chip has uptime (clock()) but no epoch -- so it errors
-- cleanly instead of answering from a clock that does not exist.  Everything
-- here is either arithmetic or an explicit time carried in:
--
--   os.date(f[, t])  = format an EXPLICIT epoch (or a literal when f has no
--                      conversion), UTC; "" and "!" need no time at all
--
-- UTC, not local: without OS timezone info local time is unimplementable, and
-- a hardcoded offset would be wrong twice a year (DST).  The harvest runs both
-- engines on one machine, so UTC-vs-local only matters where the ORACLE is
-- local -- those asserts skip on zone, correctly, rather than agree wrongly.
--
-- This is a MASTER file, installed with
--   tools/lib/libconst.py lib/os_date.lua LIB_os_date --install
-- so the text the chip parses is generated rather than hand-typed into lua.ws.
os = os or {}
local function isleap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end
local _md = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
local _mn = {"January", "February", "March", "April", "May", "June", "July",
             "August", "September", "October", "November", "December"}
local _wn = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
             "Saturday"}
-- days since 1970-01-01 (Howard Hinnant's days_from_civil): exact for any year
-- a double distinguishes, which is every year PUC's tests use.  All divisions
-- are `//`, never `/`: `/` tags float (and "2024.0" is not a year), while `//`
-- on integers tags int -- which is what every date field must be, because they
-- end up concatenated into strings.
local function dcivil(y, m, d)
  if m <= 2 then y, m = y - 1, m + 12 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m - 3) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
-- civil date from days since epoch (civil_from_days): the inverse, same range.
local function civil(z)
  z = z + 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + 3
  if m > 12 then y, m = y + 1, m - 12 end
  return y, m, d
end
local function parts(t)
  -- an integral float epoch formats with ".0" everywhere downstream, so take
  -- the integer tag when there is one; a fractional epoch keeps its tag.
  t = _m(13, t, 0) or t
  local days = t // 86400
  local sod = t - days * 86400
  local h = sod // 3600
  local mi = (sod - h * 3600) // 60
  local s = sod - h * 3600 - mi * 60
  local y, m, d = civil(days)
  -- No installation represents every year: past the 32-bit int range the
  -- answer is an error with PUC's own words, not a 36-billion year.  Checked
  -- here, once, because both os.date paths come through parts.
  if y < -2147483648 or y > 2147483647 then
    error("date result cannot be represented in this installation", 3)
  end
  local wday = (days + 4) % 7 + 1
  if wday < 1 then wday = wday + 7 end
  local yday = dcivil(y, m, d) - dcivil(y, 1, 1) + 1
  return y, m, d, h, mi, s, wday, yday
end
local function pad2(n)
  n = n - n % 1
  if n < 10 then return "0" .. n end
  return "" .. n
end
-- week number: jan1w is Jan 1's weekday (0 = Sunday for %U, Monday-based for
-- %W via wdmo).  Days before the first such weekday are week 0.
local function weekno(yday, jan1w)
  local first = (7 - jan1w) % 7
  if yday - 1 < first then return "00" end
  return pad2(1 + (yday - 1 - first) // 7)
end
os.date = function(f, t)
  if f == nil then
    error("bad argument #1 to 'os.date' (no clock)", 2)
  end
  if f == "" or f == "!" then return "" end
  -- "*t" answers a TABLE, not a string: year/month/day/hour/min/sec plus wday
  -- (Sunday is 1), yday and isdst (false -- everything here is UTC).  "!*t" is
  -- the same table, since UTC is all there is.
  local st = 1
  if _s(1, f, 0, 1) == "!" then st = 2 end
  if _s(1, f, st - 1, 2) == "*t" and st + 2 > #f then
    if t == nil then
      error("bad argument #1 to 'os.date' (no clock)", 2)
    end
    local y, m, d, h, mi, s, wday, yday = parts(t)
    return {year = y, month = m, day = d, hour = h, min = mi, sec = s,
            wday = wday, yday = yday, isdst = false}
  end
  -- "!" selects UTC; everything here IS UTC (no OS timezone exists), so it is
  -- consumed and changes nothing -- which is the documented boundary, not an
  -- oversight.  Kept as an index, not a slice, and every string read below is
  -- a _s gate: f:sub/f:find are PIECES the loader only installs when the
  -- PROGRAM names them, so a date-only program would find them nil -- and a
  -- :sub on a table element (_mn[m]:sub) is the unfixed s[m]() shape besides.
  local has = false
  local k = st
  while k <= #f do
    if _s(1, f, k - 1, 1) == "%" then has = true break end
    k = k + 1
  end
  if not has then
    if st == 1 then return f end
    return _s(1, f, st - 1, #f - st + 1)
  end
  if t == nil then
    error("bad argument #1 to 'os.date' (no clock)", 2)
  end
  local y, m, d, h, mi, s, wday, yday = parts(t)
  local w = wday - 1
  local jan1w = (w - (yday - 1)) % 7
  local out = ""
  local i = st
  while i <= #f do
    local c = _s(1, f, i - 1, 1)
    if c ~= "%" then
      out = out .. c
      i = i + 1
    else
      local k2 = _s(1, f, i, 1)
      -- E/O modifiers (C locale: same as the base): consume the extra letter
      if (k2 == "E" or k2 == "O") and i + 1 <= #f then
        k2 = k2 .. _s(1, f, i + 1, 1)
        i = i + 1
      end
      if k2 == "Y" then out = out .. y
      elseif k2 == "m" then out = out .. pad2(m)
      elseif k2 == "d" then out = out .. pad2(d)
      elseif k2 == "H" then out = out .. pad2(h)
      elseif k2 == "M" then out = out .. pad2(mi)
      elseif k2 == "S" then out = out .. pad2(s)
      elseif k2 == "w" then out = out .. w
      elseif k2 == "y" or k2 == "Oy" then out = out .. pad2(y % 100)
      elseif k2 == "j" then
        local jy = "" .. yday
        while #jy < 3 do jy = "0" .. jy end
        out = out .. jy
      elseif k2 == "U" then out = out .. weekno(yday, jan1w)
      elseif k2 == "W" then out = out .. weekno(yday, (jan1w + 6) % 7)
      elseif k2 == "a" then out = out .. _s(1, _wn[w + 1], 0, 3)
      elseif k2 == "A" then out = out .. _wn[w + 1]
      elseif k2 == "b" or k2 == "h" then out = out .. _s(1, _mn[m], 0, 3)
      elseif k2 == "B" then out = out .. _mn[m]
      elseif k2 == "p" then out = out .. (h < 12 and "AM" or "PM")
      elseif k2 == "c" then
        -- C locale on this CRT spells %c as "%x %X", not the glibc long form:
        -- the oracle defines truth here, and it says "01/01/70 01:00:00".
        out = out .. pad2(m) .. "/" .. pad2(d) .. "/" .. pad2(y % 100) .. " "
                  .. pad2(h) .. ":" .. pad2(mi) .. ":" .. pad2(s)
      elseif k2 == "x" or k2 == "Ex" then
        out = out .. pad2(m) .. "/" .. pad2(d) .. "/" .. pad2(y % 100)
      elseif k2 == "X" then
        out = out .. pad2(h) .. ":" .. pad2(mi) .. ":" .. pad2(s)
      elseif k2 == "e" then
        out = out .. (d < 10 and " " .. d or "" .. d)
      elseif k2 == "s" then out = out .. (t - t % 1)
      elseif k2 == "%" then out = out .. "%"
      else out = out .. "%" .. k2
      end
      i = i + 2
    end
  end
  return out
end
