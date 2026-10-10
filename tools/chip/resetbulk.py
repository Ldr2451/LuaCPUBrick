"""Reset-payload census: which resizes cost elements a program never uses.

vmReset still writes ~160k elements per run after the table heap left it
(tools/chip/resetbulk.py).  A program touches a few hundred of them, and the
game prices every one.  A static census pairs every reset resize with its
const, so candidates are ranked by payload rather than by eye -- the same job
bulkprof.py does by measurement, without having to run it.

  python -u tools/chip/resetbulk.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WS = io.open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()


def consts():
    out = {}
    for k, v in re.findall(r"const (\w+) = ([\w\s()*+\-*.]+)",
                           WS):
        try:
            out[k] = eval(v, {}, {}) if any(c in v for c in "(+") else int(v)
        except Exception:
            out[k] = None
    return out


def braced(i):
    i = WS.index("{", i)
    depth, j = 0, i
    while True:
        if WS[j] == "{":
            depth += 1
        elif WS[j] == "}":
            depth -= 1
            if not depth:
                return WS[i:j + 1]
        j += 1


def body(name):
    for prefix in ("mod %s(" % name, "chip %s(" % name):
        if prefix in WS:
            return braced(WS.index(prefix))
    return None


def main():
    C = consts()
    grand = 0
    for name in ("vmReset", "parseInit"):
        b = body(name) or ""
        total = 0
        rows = []
        for m in re.finditer(r"(\w+)\.resize\(([^,()]+)", b):
            arr, sz = m.group(1), m.group(2).strip()
            n = C.get(sz, int(sz) if sz.isdigit() else None)
            if n is None:
                rows.append("  %-12s size=%-24s UNPARSED" % (arr, sz))
                continue
            total += n
        grand += total
        print("== %s  parsed payload = %d" % (name, total))
    print("total known payload = %d" % grand)
    # EXPR forms are the ones to resolve by hand: MAX_FUNCS + MAX_CLO etc.
    for name in ("vmReset", "parseInit"):
        b = body(name) or ""
        for m in re.finditer(r"(\w+)\.resize\(([^,()]*(?:\(|\))[^,)]*)", b):
            arr, sz = m.group(1), m.group(2).strip()
            print("  EXPR %-12s size=%s" % (arr, sz))
    return 0


if __name__ == "__main__":
    sys.exit(main())
