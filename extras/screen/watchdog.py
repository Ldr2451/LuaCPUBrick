"""Per-tick structural checks for the screen chip -- cheap, scene-free.

The chip is one combinational graph whose passes coordinate through
shared state (see the contract map in gen.py).  Most scheduling bugs
corrupt that state BEFORE the wall shows anything wrong: spans stop
pairing, a walk's counter freezes.  These checks watch the state, not
the pixels, every tick -- seconds of overhead -- so a gen.py edit that
mis-coordinates passes says so at the tick it starts, instead of hours
later through a chain pixel-diff.

  from watchdog import make_watch
  wd = make_watch(sim)          # after fresh_sim, before sim.run
  def watch(sn, tick):
      wd(sn, tick)
      ...
  wd.dump()                     # print first violations; [] means clean

Checked every tick (structural, from the gen.py contract):
  span pairing   a row's old/cov extents satisfy min <= max, or sit
                 exactly at the (200, -200) sentinel pair
  sentinel reach extents never leave [-200, 200]
  walk progress  while erasing, erRow advances; while the iterator
                 runs (rcOn), rcSlot or prow advance; while polyOn,
                 prow advances -- a frozen walk is the
                 "chip sits erasing true forever" class
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)),
                                "irrun"))
from irsims import _extract  # noqa: E402 -- the suite's label reader

SENT = (200.0, -200.0)
SENT_TOL = 0.5


def var_id(sim, name):
    for nid, nd in sim.nodes.items():
        if _extract(nd.props.get("_label", ("raw", ""))) == name:
            return nid
    raise RuntimeError("no var %r" % name)


def make_watch(sim):
    """Returns wd(sn, tick); collect with wd.dump()/wd.failures()."""
    vids = {}
    for n in ("erasing", "rcOn", "polyOn", "sOn"):
        try:
            vids[n] = var_id(sim, n)
        except RuntimeError:
            pass
    for n in ("erRow", "rcSlot", "prow", "prow2"):
        try:
            vids[n] = var_id(sim, n)
        except RuntimeError:
            pass
    # staging's own state: while any of it runs, the iterator may legally
    # hold its slot until the handoff lands (contract: staging arms the
    # other passes), so a still iterator is only a violation when nothing
    # else owns progress
    for n in ("pending", "commitR", "commitQ", "arming", "armingS"):
        try:
            vids[n] = var_id(sim, n)
        except RuntimeError:
            pass

    fails = []
    st = {"prev_er": None, "er_stall": 0, "prev_it": None, "it_stall": 0,
          "prev_row": None, "row_stall": 0}

    def wd(sn, tick):
        cov = sn.chip_array("covMin"), sn.chip_array("covMax")
        old = sn.chip_array("oldMin"), sn.chip_array("oldMax")
        for nm, (mn, mx) in (("cov", cov), ("old", old)):
            if mn is None or mx is None:
                continue
            for r in range(len(mn)):
                a, b = float(mn[r]), float(mx[r])
                if a > b + SENT_TOL and not (a > SENT[0] - SENT_TOL
                                             and b < SENT[1] + SENT_TOL):
                    if len(fails) < 12:
                        fails.append("t%-5d span %s[%d]=[%s,%s] unpaired"
                                     % (tick, nm, r, a, b))
                if a < -200.5 or a > 200.5 or b < -200.5 or b > 200.5:
                    if len(fails) < 12:
                        fails.append("t%-5d span %s[%d] out of wall"
                                     % (tick, nm, a, b))
        g = lambda n: sn.vars.get(vids[n]) if n in vids else None
        if g("erasing") is not None and g("erRow") is not None:
            e = bool(g("erasing"))
            er = float(g("erRow"))
            if e and st["prev_er"] is not None and er == st["prev_er"]:
                st["er_stall"] += 1
                if st["er_stall"] == 4 and len(fails) < 12:
                    fails.append("t%-5d frozen erase walk: erRow stuck at %s"
                                 % (tick, er))
            st["prev_er"] = er if e else None
        if (g("rcOn") is not None and g("rcSlot") is not None
                and g("prow") is not None):
            if bool(g("rcOn")):
                key = (round(float(g("rcSlot")), 2),
                       round(float(g("prow")), 1), round(float(g("prow2")),
                       1) if g("prow2") is not None else None)
                busy_staging = any(bool(g(n)) for n in
                                   ("pending", "commitR", "commitQ",
                                    "arming", "armingS", "erasing") if n in vids)
                if st["prev_it"] == key and not busy_staging:
                    st["it_stall"] += 1
                    if st["it_stall"] == 6 and len(fails) < 12:
                        fails.append("t%-5d frozen iterator: rcSlot/prow stuck"
                                     % (tick,))
                else:
                    st["it_stall"] = 0
                st["prev_it"] = key
            else:
                st["prev_it"] = None
        if g("polyOn") is not None and g("prow") is not None:
            if bool(g("polyOn")):
                r = round(float(g("prow")), 2)
                if st["prev_row"] == r:
                    st["row_stall"] += 1
                    if st["row_stall"] == 4 and len(fails) < 12:
                        fails.append("t%-5d frozen paint walk: prow stuck at %s"
                                     % (tick, r))
                st["prev_row"] = r
            else:
                st["prev_row"] = None

    wd.failures = lambda: fails
    wd.dump = lambda: [print(f) for f in fails]
    return wd
