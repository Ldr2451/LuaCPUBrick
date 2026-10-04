"""What each library FUNCTION costs at boot, so a split can be picked by number.

A piece's price is its characters and its function count, but which piece to split
is not obvious from its length: `math_trig` is 340 escaped chars of almost pure
`_m(n, x, 0)` one-liners, while `tab_ins` is 606 chars with two real loops.  This
measures the thing the decision actually needs -- the boot ticks a program pays for
naming ONE function, with the current piece layout -- so a split can be argued from
a delta instead of from a character count.

It also prints the marginal cost inside the piece: naming a second function from
the same piece costs almost nothing, because the piece's characters are already
spliced.  That difference (first function vs second) IS what a split recovers.

  python -u tools/chip/libcost.py
  python -u tools/chip/libcost.py math string
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "irrun"))
from irsims import ChipRunner  # noqa: E402

CAP = 30000

# group -> functions, and a call that touches only that one function
GROUPS = {
    "math": [
        ("math.floor", "print(math.floor(1.5))"),
        ("math.ceil", "print(math.ceil(1.5))"),
        ("math.abs", "print(math.abs(-1))"),
        ("math.sqrt", "print(math.sqrt(4))"),
        ("math.type", "print(math.type(1))"),
        ("math.tointeger", "print(math.tointeger(1))"),
        ("math.sin", "print(math.sin(0))"),
        ("math.cos", "print(math.cos(0))"),
        ("math.tan", "print(math.tan(0))"),
        ("math.asin", "print(math.asin(0))"),
        ("math.acos", "print(math.acos(1))"),
        ("math.atan", "print(math.atan(0))"),
        ("math.exp", "print(math.exp(0))"),
        ("math.log", "print(math.log(1))"),
        ("math.max", "print(math.max(1))"),
        ("math.min", "print(math.min(1))"),
        ("math.fmod", "print(math.fmod(7, 3))"),
        ("math.modf", "print(math.modf(1.5))"),
        ("math.pi", "print(math.pi)"),
        ("math.random", "print(math.random(1))"),
    ],
    "string": [
        ("string.len", "print(string.len('ab'))"),
        ("string.sub", "print(string.sub('ab', 1))"),
        ("string.byte", "print(string.byte('a'))"),
        ("string.char", "print(string.char(97))"),
        ("string.rep", "print(string.rep('a', 2))"),
        ("string.reverse", "print(string.reverse('ab'))"),
        ("string.upper", "print(string.upper('a'))"),
        ("string.format", "print(string.format('%d', 1))"),
        ("string.find", "print(string.find('ab', 'a'))"),
        ("string.gsub", "print(string.gsub('ab', 'a', 'c'))"),
        ("string.gmatch", "print(string.gmatch('a', 'a') ~= nil)"),
    ],
    "table": [
        ("table.insert", "local t = {} table.insert(t, 1) print(1)"),
        ("table.remove", "local t = {1} table.remove(t) print(1)"),
        ("table.concat", "print(table.concat({1}))"),
        ("table.sort", "local t = {1} table.sort(t) print(1)"),
        ("table.unpack", "print(table.unpack({1}))"),
        ("table.pack", "print(table.pack(1).n)"),
        ("table.move", "print(table.move({1}, 1, 1, 1) ~= nil)"),
    ],
    "base": [
        ("(nothing)", "print(1)"),
        ("print", "print(1)"),
        ("pairs", "for k in pairs({1}) do end print(1)"),
        ("ipairs", "for k in ipairs({1}) do end print(1)"),
        ("tonumber", "print(tonumber('1'))"),
        ("type", "print(type(1))"),
        ("select", "print(select('#', 1))"),
        ("tostring", "print(tostring(1))"),
        ("error", "print(pcall(error, 'x'))"),
        ("io.write", "io.write('x')"),
    ],
}

BASE_NAME = "(nothing)"


def main(argv):
    want = [a.lower() for a in argv] or sorted(GROUPS)
    runner = ChipRunner(os.path.join(ROOT, "lua.ws"))

    def boot(src):
        runner.sim.reset()
        runner.sim.inputs = {"program": src, "run": True}
        seen = {}

        def watch(sim, tick, seen=seen):
            if "first" not in seen and sim.log:
                seen["first"] = tick

        runner.sim.run(CAP, on_tick=watch)
        return seen.get("first")

    # measured here rather than taken from the `base` group, so the marginal costs
    # mean the same thing whichever groups were asked for
    base = boot(GROUPS["base"][0][1])
    rows = []
    for group in want:
        if group not in GROUPS:
            print("no such group: %s (have %s)" % (group, sorted(GROUPS)))
            return 1
        for name, src in GROUPS[group]:
            first = boot(src)
            rows.append((name, first))

    print("baseline (nothing) = %s ticks to first output" % base)
    print("%-16s %7s %9s" % ("function", "boot", "marginal"))
    for name, first in rows:
        if first is None:
            print("%-16s %7s %9s   NO OUTPUT (not reached, or over the cap)"
                  % (name, "-", "-"))
        else:
            print("%-16s %7d %+9d" % (name, first, first - base))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
