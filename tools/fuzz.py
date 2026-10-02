"""Seeded differential fuzzer for the chip: random valid programs, chip vs
real Lua oracle. Only generates programs both sides must accept with
identical logs (documented divergences are excluded by construction).

Usage: python -u tools/fuzz.py [count=40] [seed0=1]
Exit 0 when every seed was COMPARED and agreed; 1 on a failing seed or on any
unexplained skip (see SKIP_REASONS).

The default is deliberately small: a seed costs an oracle run and a chip run, so
150 seeds measured 2.5 minutes and 400 measured 6.  That is a before-you-ship
sweep, not an edit-loop command -- the suite and tools/check.py are the fast
paths, and `1 <seed>` is about 5 seconds when you want one program.

The skip rate was the generator, in two rounds.  First it was scope: a name
being defined was offered to its own initialiser (`w5 = (w5 % 3)`, `local v7 = v7
+ 1`), a local from a `then` arm stayed in scope for the `else` arm, and a local
declared in a block outlived it.  Each of those is a read of an undeclared global,
which PUC answers with "attempt to perform arithmetic on a nil value".  Then,
with the scope right, 30 of 150 were still skipped and all 30 were the SAME
cause: the outstr arm of the generator never closed its own paren, so the program
was a syntax error, the oracle rejected it before the chip ran, and the harness
called that a skip.  Measured on 150 seeds: 50 agreed and 100 skipped at the
start, 119 agreed and 30 skipped after the scope fix, 149 agree and 0 skip now.
"""
import concurrent.futures as cf
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))
from test_chip_suite import run_case

INPUTS = [2.5, -1.0, 0.5, 8.0]
SINPUTS = {0: "ab", 1: "c d"}
VEC = (1.0, -2.0, 0.5)
COL = (0.25, 0.5, 0.75, 1.0)
INARR = [1.5, -2.25, 4.0]
SAFE_STRS = ["x", "yz", "a b", "0", "T", "q\\nq", "s\\t1"]
NUMC = ["0", "1", "2.5", "3", "0.5", "-4", "10"]


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.env = {}      # name -> type in {"num","str","bool","table","nil"}
        self.tinfo = {}    # table name -> {"ints": set, "strs": set}
        self.funcs = {}    # name -> arity (all num->num)
        self.n = 0

    def var(self, typ):
        c = [k for k, v in self.env.items() if v == typ]
        return self.r.choice(c) if c else None

    def expr(self, typ, depth=0):
        r = self.r
        if depth > 3:
            return self.leaf(typ)
        c = r.random()
        if typ == "num":
            if c < 0.30:
                return self.leaf("num")
            if c < 0.45:
                a, b = self.expr("num", depth + 1), self.expr("num", depth + 1)
                return f"({a} {r.choice(['+', '-', '*'])} {b})"
            if c < 0.52:
                return f"({self.expr('num', depth + 1)} / {r.choice(['1', '2', '0.5', '-4'])})"
            if c < 0.58:
                return f"({self.expr('num', depth + 1)} % {r.choice(['2', '3', '5'])})"
            if c < 0.64:
                return f"({self.leaf('num')} ^ {r.choice(['2', '3'])})"
            if c < 0.70:
                # parenthesised: bare `--x` would lex as a comment
                return f"(-({self.expr('num', depth + 1)}))"
            if c < 0.76:
                t = self.table_with_ints()
                if t is not None:
                    return f"(#{t} + 0)"
                return self.leaf("num")
            if c < 0.82 and self.funcs:
                f = r.choice(sorted(self.funcs))
                args = ", ".join(self.expr("num", depth + 1)
                                 for _ in range(self.funcs[f]))
                return f"({f}({args}))"
            if c < 0.88:
                # + 0 keeps it a float on the oracle too (bare # yields
                # an int there, which no string comparison can tell
                # apart from a printed int-looking string)
                return f"((#{self.expr('str', depth + 1)}) + 0)"
            return f"(innumarr({r.choice(['1', '2', '3'])}) + 0)"
        if typ == "str":
            if c < 0.35:
                return self.leaf("str")
            if c < 0.55:
                return (f"({self.expr('str', depth + 1)} .. "
                        f"{self.expr('str', depth + 1)})")
            if c < 0.70:
                return f"(tostring({self.expr(r.choice(['num', 'str', 'bool', 'nil']), depth + 1)}))"
            if c < 0.80:
                return f"({self.expr('str', depth + 1)} .. {self.expr('num', depth + 1)})"
            return self.leaf("str")
        if typ == "bool":
            if c < 0.40:
                t = r.choice(["num", "str"])
                return (f"({self.expr(t, depth + 1)} "
                        f"{r.choice(['<', '<=', '==', '~='])} "
                        f"{self.expr(t, depth + 1)})")
            if c < 0.46:
                return (f"({self.expr('num', depth + 1)} == "
                        f"{self.expr('str', depth + 1)})")
            if c < 0.55:
                return f"({self.expr('bool', depth + 1)} {r.choice(['and', 'or'])} {self.expr('bool', depth + 1)})"
            if c < 0.65:
                return f"(not {self.expr('bool', depth + 1)})"
            return self.leaf("bool")
        if typ == "nil":
            if c < 0.5 and self.tinfo:
                t = r.choice(sorted(self.tinfo))
                return f"({t}[{r.randint(50, 99)}])"
            if c < 0.75:
                return "(innumarr(99))"
            return "nil"
        return self.leaf("nil")

    def leaf(self, typ):
        r = self.r
        v = self.var(typ)
        if v is not None and r.random() < 0.7:
            if typ == "table":
                return v
            return v
        if typ == "num":
            return r.choice(NUMC + ["inNum0", "inNum1", "inNum2", "inNum3",
                                   "innumarr(1)"])
        if typ == "str":
            return r.choice([f"'{s}'" for s in SAFE_STRS]
                            + ["inStr0", "inStr1"])
        if typ == "bool":
            return r.choice(["true", "false"])
        return "nil"

    def table_with_ints(self):
        c = [t for t, i in self.tinfo.items() if i["ints"]]
        return self.r.choice(c) if c else None

    def printable(self, depth=0):
        return self.expr(self.r.choice(["num", "str", "bool", "nil"]),
                         depth)

    def stmt(self, depth=0):
        r = self.r
        c = r.random()
        self.n += 1
        g = f"g{self.n % 5}"
        if depth > 2:
            c = 0.99  # leaf statements only
        if c < 0.16:
            args = ", ".join(self.printable(1)
                             for _ in range(r.randint(0, 3)))
            return f"print({args})"
        if c < 0.30:
            t = r.choice(["num", "str", "bool"])
            n = f"v{self.n}"
            # same as the w case: the initialiser runs before the local is bound,
            # so offering the name to it reads a global with no value
            prev = self.env.pop(n, None)
            e = self.expr(t, 1)
            self.env[n] = t
            return f"local {n} = {e}"
        if c < 0.40:
            n = f"w{self.n}"
            # The name being defined must not be offered to its own right-hand
            # side: `w5 = (w5 % 3)` reads a global that has no value yet, and the
            # oracle rightly raises "attempt to perform arithmetic on a nil value
            # (global 'w5')" -- and a call through it fails again one level down
            # as "local 'p0'", which is what two thirds of the skips were.
            prev = self.env.pop(n, None)
            e = self.expr("num", 1)
            self.env[n] = "num"
            return f"{n} = {e}"
        if c < 0.50 and self.env:
            a = r.choice(sorted(self.env))
            ta = self.env[a]
            if ta == "table":
                return self.tstmt(a)
            b = self.var(ta)
            if b is None:
                b = self.expr(ta, 1)
            return f"{a}, {g} = {b}, {self.expr(ta, 1)}"
        if c < 0.58 and self.tinfo:
            return self.tstmt(r.choice(sorted(self.tinfo)))
        if c < 0.68:
            t = self.expr("bool", 1)
            # a local declared inside the block is gone when the block ends, so
            # the env has to go back to what it was: reading one afterwards is a
            # read of an undeclared GLOBAL, which is nil and then arithmetic on it
            saved = dict(self.env)
            s1 = self.stmt(depth + 1)
            # the branches are exclusive scopes: a local from the then arm is not
            # in scope in the else arm, and offering it there builds a read of an
            # undeclared global
            self.env.clear()
            self.env.update(saved)
            s2 = self.stmt(depth + 1) if r.random() < 0.5 else None
            self.env.clear()
            self.env.update(saved)
            s = f"if {t} then {s1}"
            if s2:
                s += f" else {s2}"
            return s + " end"
        if c < 0.76:
            n = r.randint(1, 4)
            k = self.n
            saved = dict(self.env)
            body = " ".join(self.stmt(depth + 1)
                            for _ in range(r.randint(1, 3)))
            self.env.clear()
            self.env.update(saved)
            brk = " if g0 then break end" if r.random() < 0.4 else ""
            return (f"local _k{k} = 1 while _k{k} <= {n} do "
                    f"{body}{brk} _k{k} = _k{k} + 1 end")
        if c < 0.84:
            return f"outarr({r.randint(1, 4)}, {self.expr('num', 1)})"
        if c < 0.90:
            # the closing ')' of outstr( is part of the format string, exactly as
            # it is for outarr and outnum above.  It was missing, so every program
            # that took this arm was missing a paren: the oracle rejected it as a
            # SYNTAX error before the chip ran, and the harness counted that as a
            # skip -- which is how 30 of 150 seeds went uncompared while the tool
            # still reported a clean run.
            return (f"outnum({r.randint(1, 4)}, {self.expr('num', 1)})"
                    if r.random() < 0.6 else
                    f"outstr({r.randint(1, 2)}, {self.expr('str', 1)})")
        args = ", ".join(self.printable(1) for _ in range(r.randint(0, 2)))
        return f"print({args})"

    def tstmt(self, t):
        r = self.r
        info = self.tinfo[t]
        c = r.random()
        if c < 0.45 and info["ints"]:
            k = r.choice(sorted(info["ints"]))
            return f"{t}[{k}] = {self.expr('num', 1)}"
        if c < 0.60 and info["strs"]:
            k = r.choice(sorted(info["strs"]))
            return f"{t}.{k} = {self.expr(r.choice(['num', 'str']), 1)}"
        if c < 0.72:
            k = max(info["ints"] or [0]) + 1
            info["ints"].add(k)
            return f"{t}[{k}] = {self.expr('num', 1)}"
        if c < 0.84:
            k = f"k{self.n}"
            info["strs"].add(k)
            return f"{t}['{k}'] = {self.expr('str', 1)}"
        k = r.choice(sorted(info["ints"] or [1]))
        return f"print({t}[{k}])"

    def program(self):
        r = self.r
        pre = []
        for i in range(r.randint(1, 2)):
            n = f"f{i}"
            ar = r.randint(1, 2)
            self.funcs[n] = ar
            self.env[n] = "func"
            a = ", ".join(f"p{j}" for j in range(ar))
            body = " + ".join([f"p{j}" for j in range(ar)] + ["1"])
            pre.append(f"function {n}({a}) return {body} end")
        for i in range(r.randint(1, 2)):
            n = f"t{i}"
            self.env[n] = "table"
            ni = r.randint(1, 3)
            elems = [r.choice(NUMC) for _ in range(ni)]
            elems.append(f"s{i} = 'v{i}'")
            self.tinfo[n] = {"ints": set(range(1, ni + 1)),
                             "strs": {f"s{i}"}}
            pre.append(f"{n} = {{{', '.join(elems)}}}")
        self.env["g0"] = "bool"
        pre.append("g0 = false")
        body = [self.stmt() for _ in range(r.randint(6, 12))]
        body.append(f"print({self.printable(1)})")
        return "\n".join(pre + body) + "\n"


def one(seed):
    g = Gen(random.Random(seed))
    return g.program()


def _lit(text):
    """The two sides of a mismatch, as the strings they are."""
    # the lua literal ends the message, so there is no trailing space after it
    got = re.search(r"chip=('(?:[^'\\]|\\.)*'|\[.*?\])(?:\s|$)", text)
    want = re.search(r"lua=('(?:[^'\\]|\\.)*'|\[.*?\])(?:\s|$)", text)
    if not got or not want:
        return None, None
    return eval(got.group(1)), eval(want.group(1))


def only_neg_zero(text):
    """True when the ONLY difference is the sign of a printed negative zero."""
    got, want = _lit(text)
    if not isinstance(got, str) or not isinstance(want, str):
        return False
    # "0.0" <-> "-0.0" is the class; a 1 inside a digit run ("1-0.0") is PUC
    # concatenating 1 and -0.0, which is the same divergence one step along
    signless = lambda s: s.replace("-0.0", "0.0").replace("1-0.0", "10.0")
    return signless(got) == signless(want) and got != want


# A skip is a program that was never compared, and an uncompared program is not
# a pass.  This is the fuzzer's version of the suite's SKIP dict, and it exists
# because of what a skip actually hid here: the outstr arm of the generator was
# missing its own closing paren, so every program that took it was unparseable,
# the oracle rejected all of them as SYNTAX errors, and 30 of 150 seeds were
# counted as skips -- which this tool reported as a clean run, because the exit
# code only ever looked at `fails`.  With the oracle missing entirely it would
# have reported 0/150 and exited 0.
#
# So a skip fails the run unless its seed is named here WITH the reason it is
# uncompareable.  There are none, and the list is empty on purpose: the generator
# only emits programs both sides must accept (see the module docstring), so a skip
# means the generator or the environment is wrong, not that the seed is hard.
# Delete the `or skips` from the return below and this comment is the net that
# stops firing -- which is how you check it still can.
SKIP_REASONS = {}


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    seed0 = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    # The numeric inputs go in kw, not in run_case's `inputs` argument: that
    # argument is not forwarded (run_case only passes kw through), so passing
    # them there left inNum0..3 nil on BOTH sides and two thirds of the
    # programs came back "oracle rejected".
    kw = {"inputs": INPUTS, "sinputs": SINPUTS, "vec": VEC, "col": COL,
          "innumarr": INARR}
    jobs = [("fuzz-%d" % (seed0 + k), one(seed0 + k)) for k in range(count)]
    fails = skips = known = 0
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(run_case, name, src, None, "run", dict(kw)): name
                for name, src in jobs}
        for f in cf.as_completed(futs):
            name, good, detail, dt = f.result()
            if good is None:
                if name not in SKIP_REASONS:
                    print(f"SKIP {name}: {detail}", flush=True)
                skips += 1
            elif good:
                pass
            elif only_neg_zero(detail):
                # The one divergence the fuzzer keeps finding is the sign of a
                # negative zero: the host's `..` answers "0" for every zero
                # (`if !f.is_finite() || *f == 0.0`) while PUC keeps the sign, and
                # the chip's own fmtNum answers "-0.0".  Reporting it as a FAIL
                # every run trains the reader to ignore FAILs, so it gets its own
                # count and says which class it was.
                print(f"KNOWN {name} ({dt:.1f}s): negative zero only: {detail}",
                      flush=True)
                known += 1
            else:
                src = dict(jobs)[name]
                print(f"FAIL {name} ({dt:.1f}s): {detail}\n{src}",
                      flush=True)
                fails += 1
    print("%d/%d agree (%d skipped, %d known negative-zero)"
          % (count - fails - skips - known, count, skips, known))
    # `or skips` is the rule above, and it is what makes the tool's exit code
    # mean "compared and agreed" rather than "did not find anything".
    return 1 if fails or skips else 0


if __name__ == "__main__":
    sys.exit(main())
