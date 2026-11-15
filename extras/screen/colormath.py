"""Colour arithmetic on the official simulator (test support): nothing to do.

The retired model lowered `color` arithmetic onto the same math gate as float
arithmetic and this module patched that gate so `+ - * /` ran RGBA channel-
wise.  The official simulator does not lower it that way: the certified table
runs `Math*` on NUMBERS, so a colour minus a colour is refused at runtime
("not certified for inputs (color, color)"), and the one gate class that does
certify colours, `ColorBlend`, is deferred -- probed and always refused.  So
the screen's generator emits the certified form instead, channel by channel
rejoining at `Color()` (see `wcol_lerp`/`wcol_subscale`/`wcol_lerp_keep` in
gen.py): the arithmetic the old patch stood in for is now in the chip, where
the simulator can check it gate by gate.

`install()` stays because the paint drivers name it; it installs nothing.
"""


def install():
    """A no-op, kept so the paint drivers' preamble stays one line."""
    return None
