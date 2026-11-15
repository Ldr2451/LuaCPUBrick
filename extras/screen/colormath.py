"""Channel-wise colour math for the tick sim (test support).

The compiler lowers `color` arithmetic onto the same math gate as
float arithmetic -- the docs are explicit that the gate's variant
set covers `LinearColor`, so `+ - * /` operate **RGBA channel-wise**
on two `color` operands and mixing a colour with a number
broadcasts the number across the channels.  The sim's own
`Expr_Math*` evaluation is float-only (`_as_float` coerces a colour
tuple to 0.0), so without this patch every interpolated pixel reads
back as 0.0 and no colour value is testable.

This patches the sim class at import time -- the repo's irrun/
simulator is shared, untouched repo infrastructure, while the
colour feature and its tests live under extras/screen.  Anything
that does not use colour math is unaffected: the patch only
diverts when an operand actually is a colour tuple.

  import colormath; colormath.install()   # before sim_from_dump
"""
from __future__ import annotations

from typing import Any

from irsims import Sim, _as_float  # noqa: E402

_orig_arith = Sim._do_arith


def _chan(v):
    """A colour's channels as floats (a scalar broadcasts)."""
    if isinstance(v, (tuple, list)):
        return [float(x) for x in v], True
    return _as_float(v, 0.0), False


def _do_arith_color(self, nid, nq, op):
    """_do_arith, extended with the documented LinearColor variants:
    colour-op-colour is channel-wise, colour-op-scalar broadcasts
    the scalar, and everything else falls through to the float
    path the sim already had."""
    a = self._in_val(nid, "InputA", 0)
    b = self._in_val(nid, "InputB", 0)
    if not (isinstance(a, (tuple, list)) or isinstance(b, (tuple, list))):
        return _orig_arith(self, nid, nq, op)
    ca, a_is_c = _chan(a)
    cb, b_is_c = _chan(b)
    if a_is_c and b_is_c:
        n = max(len(ca), len(cb))
        ca = (ca + [0.0] * n)[:n]
        cb = (cb + [0.0] * n)[:n]
        out = tuple(op(x, y) for x, y in zip(ca, cb))
    elif a_is_c:
        out = tuple(op(x, cb) for x in ca)
    else:
        out = tuple(op(ca, y) for y in cb)
    self._out_val(nid, "Output", out)


def install():
    """Patch the sim's arithmetic gate (idempotent)."""
    if Sim._do_arith is not _do_arith_color:
        Sim._do_arith = _do_arith_color
    return Sim
