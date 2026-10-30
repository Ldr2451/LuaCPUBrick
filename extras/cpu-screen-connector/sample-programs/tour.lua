local function tick()
  local c = clock()
  while clock() == c do end
end
local function nap(c)
  local t = clock()
  while clock() < t + c do end
end
local function pulse(n)
  outNum(n, 1.0)
  tick()
  outNum(n, 0.0)
end
local function putn(slot, t)
  local i = 1
  while i <= #t do
    outNumArr(slot + i - 1, table.unpack(t, i, math.min(i + 7, #t)))
    i = i + 8
  end
  return slot + #t
end
local function stage(pts, cols, xf, parent, ticks, wire, id)
  outNumArr(98, #pts * 1.0)
  local termAt = putn(1, pts)
  if cols == nil then
    outNumArr(termAt, -1.0)
  else
    outNumArr(termAt, -(1.0 + #cols / 4.0))
    putn(termAt + 1, cols)
  end
  local x = xf
  if x == nil then
    x = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}
  end
  local j = 1
  while j <= 9 do
    outStrArr(j, tostring(x[j]))
    j = j + 1
  end
  outStr(2, tostring(parent or "0"))
  outStr(1, tostring(id or ""))
  outNum(4, wire or 0.0)
  local t = ticks
  if t == nil then t = 0.0 end
  if t == -1.0 then
    outNumArr(100, -1.0)
  elseif t >= 1.0 then
    outNumArr(100, -(1.0 + t))
  else
    outNumArr(100, 0.0)
  end
end
local function show(id, pts, cols, xf, parent, ticks, wire)
  stage(pts, cols, xf, parent, ticks, wire, id)
  pulse(1)
  pulse(2)
  nap(4.6)
end
local function queue(id, pts, cols, xf, parent, ticks, wire)
  stage(pts, cols, xf, parent, ticks, wire, id)
  pulse(1)
end
local function hide(id)
  show(id, {}, nil, nil, "0")
end
local function clear()
  pulse(3)
  pulse(2)
  nap(4.6)
end
local function rep(c, n)
  local t = {}
  local i = 1
  while i <= n do
    local b = (i - 1) * 4
    t[b + 1] = c[1]
    t[b + 2] = c[2]
    t[b + 3] = c[3]
    t[b + 4] = c[4]
    i = i + 1
  end
  return t
end
local function face(v, a, b, c, d)
  local q = {a, b, c, d, a}
  local p = {}
  local i = 1
  while i <= 5 do
    local w = (q[i] - 1) * 3 + 1
    p[(i - 1) * 3 + 1] = v[w]
    p[(i - 1) * 3 + 2] = v[w + 1]
    p[(i - 1) * 3 + 3] = v[w + 2]
    i = i + 1
  end
  return p
end
local function tour()
  clear()
  print("1 slots: push, edit, delete")
  show("1", {4.0, 4.0, 0.0, 30.0, 4.0, 0.0, 30.0, 24.0, 0.0,
             4.0, 24.0, 0.0},
       {1.0, 0.2, 0.2, 1.0, 0.2, 1.0, 0.2, 1.0,
        0.2, 0.4, 1.0, 1.0, 1.0, 1.0, 0.2, 1.0}, nil, "0")
  show("2", {38.0, 4.0, 0.0, 60.0, 4.0, 0.0, 49.0, 24.0, 0.0},
       rep({0.2, 0.9, 0.9, 1.0}, 3), nil, "0")
  local pent = {}
  local k = 0
  while k < 5 do
    local a = -1.5708 + k * 1.2566
    pent[k * 3 + 1] = 16.0 + 9.0 * math.cos(a)
    pent[k * 3 + 2] = 44.0 + 9.0 * math.sin(a)
    pent[k * 3 + 3] = 0.0
    k = k + 1
  end
  show("3", pent, rep({0.8, 0.5, 1.0, 1.0}, 5), nil, "0")
  show("2", {38.0, 4.0, 0.0, 60.0, 4.0, 0.0, 49.0, 24.0, 0.0},
       rep({1.0, 0.6, 0.1, 1.0}, 3),
       {-4.0, 6.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  print("1 slots: slot 2 edited in place")
  hide("3")
  print("1 slots: slot 3 deleted")
  clear()
  print("2 strokes: wireframe, open curve, dot, gradient")
  show("4", {4.0, 6.0, 0.0, 24.0, 6.0, 0.0, 24.0, 26.0, 0.0,
             4.0, 26.0, 0.0, 4.0, 6.0, 0.0}, nil, nil, "0", nil, 1)
  local nw = 9
  local wav = {}
  local wc = {}
  k = 0
  while k < nw do
    local t = k / (nw - 1)
    wav[k * 3 + 1] = 30.0 + 30.0 * t
    wav[k * 3 + 2] = 16.0 + 9.0 * math.sin(t * 6.2)
    wav[k * 3 + 3] = 0.0
    wc[k * 4 + 1] = 1.0 - 0.8 * t
    wc[k * 4 + 2] = 0.2 + 0.8 * t
    wc[k * 4 + 3] = 0.3
    wc[k * 4 + 4] = 1.0
    k = k + 1
  end
  show("5", wav, wc, nil, "0", nil, 1)
  show("6", {48.0, 44.0, 0.0}, rep({1.0, 1.0, 0.3, 1.0}, 1),
       nil, "0", nil, 1)
  show("7", {8.0, 40.0, 0.0, 24.0, 58.0, 0.0},
       {1.0, 0.15, 0.15, 1.0, 0.15, 0.3, 1.0, 1.0}, nil, "0", nil, 1)
  clear()
  print("3 transparency: alpha blends over what is under it")
  show("1", {-6.0, -6.0, -40.0, 70.0, -6.0, -40.0,
             70.0, 70.0, -40.0, -6.0, 70.0, -40.0},
       {0.10, 0.10, 0.35, 1.0, 0.60, 0.10, 0.35, 1.0,
        1.00, 0.55, 0.15, 1.0, 0.05, 0.45, 0.55, 1.0}, nil, "0")
  local disc = {}
  k = 0
  while k < 10 do
    local a = k * 0.6283
    disc[k * 3 + 1] = 24.0 + 11.0 * math.cos(a)
    disc[k * 3 + 2] = 34.0 + 11.0 * math.sin(a)
    disc[k * 3 + 3] = 0.0
    k = k + 1
  end
  show("2", disc, rep({0.95, 0.10, 0.10, 0.5}, 10), nil, "0")
  show("3", {30.0, 20.0, 1.0, 52.0, 20.0, 1.0, 52.0, 46.0, 1.0,
             30.0, 46.0, 1.0},
       rep({0.10, 0.25, 0.95, 0.5}, 4), nil, "0")
  clear()
  print("4 immediate: id '' paints and is forgotten")
  show("1", {2.0, 2.0, 0.0, 12.0, 2.0, 0.0, 12.0, 12.0, 0.0,
             2.0, 12.0, 0.0, 2.0, 2.0, 0.0}, nil, nil, "0", nil, 1)
  show("", {18.0, 18.0, 0.0, 30.0, 18.0, 0.0, 30.0, 30.0, 0.0,
            18.0, 30.0, 0.0},
       rep({1.0, 0.85, 0.15, 1.0}, 4), nil, "0")
  show("", {32.0, 30.0, 0.0, 44.0, 30.0, 0.0, 44.0, 42.0, 0.0,
            32.0, 42.0, 0.0},
       rep({0.2, 0.9, 0.4, 1.0}, 4), nil, "0")
  print("4 immediate: a bare draw erases them")
  pulse(2)
  nap(4.6)
  clear()
  print("5 3D: a cube under a pivot, depth, a HUD on the camera")
  show("-1", {0.0, 0.0, 0.0}, nil,
       {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  show("1", {-6.0, -6.0, -40.0, 70.0, -6.0, -40.0,
             70.0, 70.0, -40.0, -6.0, 70.0, -40.0},
       {0.08, 0.08, 0.30, 1.0, 0.45, 0.10, 0.30, 1.0,
        0.90, 0.45, 0.15, 1.0, 0.05, 0.35, 0.45, 1.0}, nil, "0")
  show("2", {0.0, 0.0, 0.0}, nil,
       {32.0, 33.0, 0.0, 0.5, 0.0, 0.85, 1.0, 1.0, 1.0}, "0")
  local h = 11.0
  local v = {-h, -h, h, h, -h, h, h, h, h, -h, h, h,
             -h, -h, -h, h, -h, -h, h, h, -h, -h, h, -h}
  local fc = {{1, 2, 3, 4}, {5, 8, 7, 6}, {1, 5, 6, 2},
              {4, 3, 7, 8}, {1, 4, 8, 5}, {2, 6, 7, 3}}
  local fcol = {{1.0, 0.9, 0.6, 1.0}, {0.9, 0.5, 0.3, 1.0},
                {0.3, 0.9, 0.8, 1.0}, {0.3, 0.6, 1.0, 1.0},
                {0.9, 0.9, 0.9, 1.0}, {0.6, 0.4, 0.9, 1.0}}
  local f = 1
  while f <= 6 do
    local q = fc[f]
    queue(tostring(f + 2), face(v, q[1], q[2], q[3], q[4]),
          rep(fcol[f], 5), nil, "2", nil, 1)
    f = f + 1
  end
  pulse(2)
  nap(7.0)
  print("5 3D: six faces, one draw")
  local dd = {}
  k = 0
  while k < 10 do
    local a = k * 0.6283
    dd[k * 3 + 1] = 32.0 + 10.0 * math.cos(a)
    dd[k * 3 + 2] = 33.0 + 10.0 * math.sin(a)
    dd[k * 3 + 3] = 16.0
    k = k + 1
  end
  show("9", dd, rep({0.95, 0.12, 0.12, 0.5}, 10), nil, "0")
  local nc = 9
  local cv = {}
  local cc = {}
  k = 0
  while k < nc do
    local t = k / (nc - 1)
    cv[k * 3 + 1] = 4.0 + 56.0 * t
    cv[k * 3 + 2] = 54.0 + 6.0 * math.sin(t * 6.2)
    cv[k * 3 + 3] = 24.0
    cc[k * 4 + 1] = 0.2
    cc[k * 4 + 2] = 0.8 + 0.2 * t
    cc[k * 4 + 3] = 1.0 - 0.6 * t
    cc[k * 4 + 4] = 1.0
    k = k + 1
  end
  show("10", cv, cc, nil, "0", nil, 1)
  show("11", {2.0, 2.0, 0.0, 14.0, 2.0, 0.0, 14.0, 10.0, 0.0,
              2.0, 10.0, 0.0, 2.0, 2.0, 0.0}, nil, nil, "-1", nil, 1)
  print("6 camera: the world moves, the HUD holds")
  show("-1", {0.0, 0.0, 0.0}, nil,
       {-9.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  show("-1", {0.0, 0.0, 0.0}, nil,
       {0.0, 0.0, 12.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  show("-1", {0.0, 0.0, 0.0}, nil,
       {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0}, "0")
  print("7 animation: 8 frames of +2 x on the disc")
  -- An animated push stages DELTAS on every channel, so the scale channels
  -- must be zeroes here: 1,1,1 would grow the shape by +1 every frame.
  stage({0.0, 0.0, 0.0}, nil,
        {2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}, "0", 8.0, nil, "9")
  pulse(1)
  pulse(2)
  nap(14.0)
  print("7 animation: -1 keeps the cube turning")
  stage({0.0, 0.0, 0.0}, nil,
        {0.0, 0.0, 0.0, 0.0, 0.0, 0.04, 0.0, 0.0, 0.0}, "0", -1.0, nil, "2")
  pulse(1)
  pulse(2)
  nap(24.0)
end
print("screen tour: seven beats, looping")
while true do
  tour()
end
