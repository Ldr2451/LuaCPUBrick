import json, sys

p = r"C:\Users\Alessandro\AppData\Local\Temp\opencode\wirescript\crates\wirescript\data\inventory_brdb.json"
with open(p, encoding="utf-8") as f:
    data = json.load(f)

want = [w.lower() for w in sys.argv[1:]]
for c in data["components"]:
    cls = c["class"]
    if "WireGraph" not in cls and "Microchip" not in cls and "Clock" not in cls:
        continue
    if want and not any(w in cls.lower() for w in want):
        continue
    print(f"{cls}")
    print(f"    in : {c['inputs']}")
    print(f"    out: {c['outputs']}")
