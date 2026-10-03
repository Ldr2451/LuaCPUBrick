"""How many vSet sites write a payload the ISA says cannot be read?

docs/vm-isa's register table:

  tag 0 nil      payload ignored
  tag 1 number   num used, str ignored
  tag 2 string   str used, num ignored
  tag 3 boolean  num used, str ignored
  tag 4 function num used, str ignored
  tag 5 table    num used, str ignored
  tag 6 integer  num used, str ignored

So the STRING payload is dead at every tag but 2, and the NUMERIC payload is
dead at tags 0 and 2.  vSet writes all three cells, and it is a mod, so every
one of those writes is a separate copy at each of its call sites.

This only COUNTS, by class, so the ceiling is known before anything is changed:
it is the difference between what the chip stores and what a conforming read can
possibly look at.

  python -u tools/chip/payload.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
src = open(os.path.join(ROOT, "lua.ws"), encoding="utf-8").read()

calls, i = [], 0
while True:
    j = src.find("vSet(", i)
    if j < 0:
        break
    k, depth = j + 5, 1
    while k < len(src) and depth:
        depth += (src[k] == "(") - (src[k] == ")")
        k += 1
    calls.append(src[j:k])
    i = k


def split_args(call):
    inner = call[len("vSet("):-1]
    parts, depth, cur = [], 0, ""
    for ch in inner:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    return parts


buckets = {"both dead (tag 0)": 0, "string dead": 0, "num dead": 0,
           "neither": 0}
literal_only = {"string dead (literal tag)": 0}
other = 0
for c in calls:
    p = split_args(c)
    if len(p) != 4:
        other += 1
        continue
    _, tag, num, st = p
    lit = re.match(r"^\d+$", tag)
    if tag == "0" and num == "0.0" and st == '""':
        buckets["both dead (tag 0)"] += 1
    elif st == '""':
        buckets["string dead"] += 1
        if lit and tag != "2":
            literal_only["string dead (literal tag)"] += 1
    elif tag == "2" and num == "0.0":
        buckets["num dead"] += 1
    else:
        buckets["neither"] += 1

total = sum(buckets.values()) + other
print("vSet call sites: %d" % total)
for k, v in buckets.items():
    print("  %-18s %3d" % (k, v))
print("  %-18s %3d" % ("other arity", other))
print("\nSAFE (literal tag proves the payload dead):")
for k, v in literal_only.items():
    print("  %-26s %3d" % (k, v))
print("  %-26s %3d" % ("num dead (literal tag 2)",
                       buckets["num dead"]))
print("\nNOT safe: a computed tag could BE 2 at run time, so its string")
print("payload is not provably dead -- %d sites are left alone."
      % (buckets["string dead"]
         - literal_only["string dead (literal tag)"]))
print("the measured ceiling for dropping ALL payloads was -500 nodes")