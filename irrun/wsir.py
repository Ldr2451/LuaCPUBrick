"""Parse the Wirescript v2 `.wsir` dump (`compile --dump-ir`) into the flat
module dicts `irdump.parse_modules` hands to the simulator.

The compiler update replaced the `G[...]`/`N[...]`/`W[...]` dump with a text
IR (see `crates/wirescript-ir/FORMAT.md`): every node is a `%name = ...`
statement whose operands ARE its input wires, chip bodies are brace-nested
child modules, and class names lost the `WireGraph_`/`WireGraphPseudo_`
infix (`BrickComponentType_Exec_Var_Set` used to be
`BrickComponentType_WireGraph_Exec_Var_Set`).  This module maps that format
back onto the structure the Sim was built against:

- one module dict per `module`/chip body, parented by the owning chip's id;
- node classes spelled the OLD way (`BrickComponentType_WireGraph_*`,
  `BrickComponentType_WireGraphPseudo_Var`, `_Literal`), because the Sim
  dispatches on those substrings;
- port types spelled the OLD Rust-Debug way (`Exec`, `Array(Float)`), because
  `chip_call_groups` compares `p[1] == "Exec"`;
- literal operands become the consuming gate's properties (the same baked
  unwired-input values the old dump carried), spelled for `irdump._parse_lit`;
- every wire is stored in the module of its DESTINATION node (the sim only
  ever consumes the merged flat graph, so the older caller-side placement is
  not observable here).
"""

import json
import os
import re


class WsirError(RuntimeError):
    pass


# ---------------------------------------------------------------- tokenizer

_WSIR_TOKEN = re.compile(
    r'"(?:\\.|[^"\\])*"'                       # string (raw newlines allowed)
    r"|\#[0-9a-fA-F]{8}"                       # color literal
    r"|@[A-Za-z_][A-Za-z0-9_]*"                # module name
    r'|@"(?:\\.|[^"\\])*"'                     # quoted module name
    r"|%[A-Za-z0-9_]+"                         # value name
    r"|![A-Za-z_][A-Za-z0-9_]*|!\d+"           # metadata
    r"|-?(?:\d+\.\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?"
    r"|\d+[eE][+-]?\d+)"                       # float (signed)
    r"|inf|-inf|nan|-nan"
    r"|->|=>"
    r"|[A-Za-z_][A-Za-z0-9_]*"
    r"|-?\d+"
    r"|[=\(\)\{\}\[\],:.<>*+]"
)

_SCALARS = {
    "bool": "Bool", "int": "Int", "float": "Float", "string": "String",
    "vector": "Vector", "rotator": "Rotator", "quat": "Quat", "color": "Color",
    "entity": "Entity", "character": "Character", "controller": "Controller",
    "zone": "Zone", "teleport": "Teleport", "prefab": "PrefabRef",
    "exec": "Exec", "any": "Any", "opaque": "Opaque", "never": "Never",
}
_PRIM_TYPES = set(_SCALARS)


def tokenize(text):
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if c == ";":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        m = _WSIR_TOKEN.match(text, i)
        if not m:
            raise WsirError("unparsable text at offset %d: %r"
                            % (i, text[i:i + 40]))
        toks.append(m.group(0))
        i = m.end()
    return toks


class _Toks:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def at_end(self):
        return self.i >= len(self.t)

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else None

    def take(self):
        if self.i >= len(self.t):
            raise WsirError("unexpected EOF")
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, want):
        got = self.take()
        if got != want:
            raise WsirError("expected %r, got %r" % (want, got))
        return got

    def at_punct(self, punct):
        return self.peek() == punct


def consume_parens(tk):
    """Consume up to the ')' that closes the '(' just consumed."""
    depth = 0
    while True:
        t = tk.take()
        if t == "(":
            depth += 1
        elif t == ")":
            if depth == 0:
                return
            depth -= 1
        elif t is None:
            raise WsirError("EOF in parentheses")


def consume_braces(tk):
    """Consume up to the '}' that closes the '{' the caller just took.

    The opening brace is ALREADY consumed when this is called (the type
    parser takes it to recognise a record type), so the nesting starts at
    one.  Starting at zero instead consumed nothing at all, and the
    record's field names then read as the next port -- which is how
    `lua.ws` failed to parse at `(Codepoint: {Codepoint: int, Success:
    bool}, bSuccess: any)`: the parser saw the field name 'Codepoint'
    where it expected ')'.
    """
    depth = 1
    while depth:
        t = tk.take()
        if t == "{":
            depth += 1
        elif t == "}":
            depth -= 1
        elif t is None:
            raise WsirError("EOF in braces")


# ------------------------------------------------------------- classes/types

def old_class(kind_tok):
    """A wsir class/kind token -> the class string the Sim dispatches on."""
    if kind_tok == "_Literal":
        return "_Literal"
    core = kind_tok
    for pre in ("BrickComponentType_", "Component_"):
        if core.startswith(pre):
            core = core[len(pre):]
            break
    if core in ("Var", "ArrayVar", "MapVar"):
        return "BrickComponentType_WireGraphPseudo_" + core
    if core in ("DeltaTime", "ServerUptime", "GetUnixEpoch", "FormatDate",
                "FindPlayer"):
        return "BrickComponentType_WireGraph_" + core
    if core.startswith("Exec_") or core.startswith("Expr_"):
        return "BrickComponentType_WireGraph_" + core
    return "BrickComponentType_" + core


_INVENTORY = None


def _inventory():
    """Full class -> default input/output port lists, from the catalog."""
    global _INVENTORY
    if _INVENTORY is None:
        from irdump import WS_DIR
        # walk up to the compiler root (WS_DIR may point at `target/`)
        root = WS_DIR
        for _ in range(3):
            if os.path.isdir(os.path.join(root, "crates")):
                break
            root = os.path.dirname(root)
        path = os.path.join(
            root, "crates", "wirescript-ir", "data",
            "logic_gate_inventory.simple.json")
        with open(path, encoding="utf-8", errors="replace") as f:
            data = json.load(f)
        inv = {}
        for ent in data["entries"]:
            cls = ent["component"]["class"]
            inv[cls] = {
                "in": [(p["name"], p["type"])
                       for p in ent["component"].get("inputs", [])],
                "out": [(p["name"], p["type"])
                        for p in ent["component"].get("outputs", [])],
            }
        _INVENTORY = inv
    return _INVENTORY


_NEW_FULL = None


def _new_full_class(kind_tok):
    """The inventory's own full class name for a possibly short kind token."""
    global _NEW_FULL
    if _NEW_FULL is None:
        _NEW_FULL = {old_class(full): full for full in _inventory()}
    if kind_tok in _inventory():
        return kind_tok
    return _NEW_FULL.get(old_class(kind_tok))


def dbg_type(t):
    """A wsir type spelling -> the old Rust-Debug spelling."""
    t = t.strip()
    if t.startswith("*"):
        return "Ref(%s)" % dbg_type(t[1:])
    if t.endswith("[]"):
        return "Array(%s)" % dbg_type(t[:-2])
    if t in _SCALARS:
        return _SCALARS[t]
    m = re.match(r"map\s*<(.+)>$", t)
    if m:
        inner = m.group(1)
        depth, split = 0, None
        for i, ch in enumerate(inner):
            if ch == "<":
                depth += 1
            elif ch == ">":
                depth -= 1
            elif ch == "," and depth == 0 and split is None:
                split = i
        k, v = inner[:split], inner[split + 1:]
        return "Map(%s, %s)" % (dbg_type(k), dbg_type(v))
    return t  # records/enums/others: raw text is close enough for the sim


# ------------------------------------------------------------------ literals

_LITNUM = re.compile(r"^-?(\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)")


def _lit_float(tok):
    return repr(float(tok))


def parse_literal(tk):
    """Consume one wsir literal; return OLD-Debug-spelled text (or ('raw', s)).

    The spelling feeds `irdump._parse_lit`, which knows `Bool(true)`,
    `Int(3)`, `Float(1.5)`, `String("...")`, `Vector { x: ... }`,
    `Color { ... }`, `Object`, `Array([...])` and `Map([...])` -- forms as
    spelled by the old Rust `{:?}` printer.
    """
    tok = tk.take()
    if tok in ("true", "false"):
        return "Bool(%s)" % tok
    if tok == "null":
        return "Object"
    if tok in ("inf", "-inf", "nan", "-nan"):
        return "Float(%s)" % tok
    if tok.startswith('"'):
        return tok
    if tok.startswith("#"):
        r, g, b, a = (int(tok[i:i + 2], 16) for i in (1, 3, 5, 7))
        return "Color { r: %d, g: %d, b: %d, a: %d }" % (r, g, b, a)
    if re.match(r"^-?\d+$", tok):
        return "Int(%d)" % int(tok)
    if _LITNUM.match(tok):
        return "Float(%s)" % _lit_float(tok)
    if tok == "vec":
        tk.expect("(")
        xs = [tk.take()]
        for _ in range(2):
            tk.expect(",")
            xs.append(tk.take())
        tk.expect(")")
        return "Vector { x: %s, y: %s, z: %s }" % tuple(map(_lit_float, xs))
    if tok == "rot":
        tk.expect("(")
        parts = [tk.take()]
        for _ in range(2):
            tk.expect(",")
            parts.append(tk.take())
        tk.expect(")")
        return "Rotator { %s }" % ", ".join(
            "%s: %s" % (nm, _lit_float(v))
            for nm, v in zip(("pitch", "yaw", "roll"), parts))
    if tok == "quat":
        tk.expect("(")
        parts = [tk.take()]
        for _ in range(3):
            tk.expect(",")
            parts.append(tk.take())
        tk.expect(")")
        return "Quat { %s }" % ", ".join(
            "%s: %s" % (nm, _lit_float(v))
            for nm, v in zip(("x", "y", "z", "w"), parts))
    if tok == "lrgba":
        tk.expect("(")
        parts = [tk.take()]
        for _ in range(3):
            tk.expect(",")
            parts.append(tk.take())
        tk.expect(")")
        return "LinearColor { %s }" % ", ".join(
            "%s: %s" % (nm, _lit_float(v))
            for nm, v in zip(("r", "g", "b", "a"), parts))
    if tok == "[":
        items = []
        if not tk.at_punct("]"):
            while True:
                items.append(parse_literal(tk))
                if tk.at_punct(","):
                    tk.take()
                    continue
                break
        tk.expect("]")
        return "Array([%s])" % ", ".join(items)
    if tok == "map[":
        pairs = []
        if not tk.at_punct("]"):
            while True:
                k = parse_literal(tk)
                tk.expect("=>")
                v = parse_literal(tk)
                pairs.append("(%s, %s)" % (k, v))
                if tk.at_punct(","):
                    tk.take()
                    continue
                break
        tk.expect("]")
        return "Map([%s])" % ", ".join(pairs)
    if tok == "asset":
        tk.expect("(")
        tk.take()
        tk.expect(",")
        tk.take()
        tk.expect(")")
        return "Object"
    raise WsirError("unknown literal token %r" % tok)


# -------------------------------------------------------------------- parser

_ATTR_KEY = {
    "label": "_label",
    "side": "_reroute_side",
    "invisible": "_reroute_invisible",
    "doc": "_doc",
    "closed": "_closed",
    "handle_target": "_handle_target",
}


_LANG = None


def _propval(old_text):
    """OLD-Debug literal text -> the props tuple `_parse_lit` would have made.

    Bare wsir strings (`"noDepth"`) spell as their inner text; everything else
    handed to `irdump._parse_lit`.

    The bare-quoted form still carries Rust's escapes, so it has to be
    UNESCAPED like the `String("...")` form is: a prop spelled `"\\n"` is
    a newline, and handing the two characters through unescaped made the
    Lua chip's log arrive as a line of literal backslash-n.
    """
    if old_text.startswith('"') and old_text.endswith('"') \
            and len(old_text) >= 2:
        from irdump import _unescape_dq
        return ("str", _unescape_dq(old_text[1:-1]))
    from irdump import _parse_lit
    return _parse_lit(old_text)


class _Parser:
    def __init__(self, tk, id_floor=0):
        self.tk = tk
        self.name2id = {}
        # Auto-assigned ids start ABOVE every id the dump uses, so a node
        # the dump left unnamed can never take an id another node owns.
        self.last_id = id_floor
        self.mods = []
        self.idmod = {}          # node id -> module dict (destination side)
        self.node_by_id = {}
        # in-flight wires: (src_name, src_port|None, dst, dport)
        # dst: node id, or ('in'|'out', name) for pin nodes yet to be placed.
        self.wires = []

    def node_id_for(self, name, explicit):
        if name.isdigit():
            nid = int(name)
        elif explicit is not None:
            nid = explicit
        else:
            nid = self.last_id + 1
        self.last_id = max(self.last_id, nid)
        self.name2id[name] = nid
        return nid

    def wire(self, src_name, src_port, dst, dport):
        self.wires.append((src_name, src_port, dst, dport))

    def wire_operand(self, op, dst, dport, props):
        """A parsed operand -> one wire, or a baked property."""
        kind, a, port = op
        if kind == "ref":
            self.wire(a, port, dst, dport)
        elif props is not None:
            props[dport] = _propval(a)

    def parse_port_name(self):
        t = self.tk.take()
        if t.startswith('"'):
            return t[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        return t

    def parse_type(self):
        t = self.tk.take()
        if t == "*":
            return "*" + self.parse_type()
        if t == "array":
            return self.parse_type() + "[]"
        if t in ("map", "union", "tuple", "enum", "component", "param"):
            self.tk.expect("<")
            depth, out = 1, []
            while True:
                tok = self.tk.take()
                if tok == "<":
                    depth += 1
                elif tok == ">":
                    depth -= 1
                    if not depth:
                        break
                out.append(tok)
            inner = "".join(out)
            if t == "map":
                # split the top-level comma between K and V
                depth, pparts, cur = 0, [], ""
                for ch in inner:
                    if ch == "," and depth == 0:
                        pparts.append(cur)
                        cur = ""
                        continue
                    if ch in "<([":
                        depth += 1
                    elif ch in ">)]":
                        depth -= 1
                    cur += ch
                pparts.append(cur)
                return "Map(%s, %s)" % (dbg_type(pparts[0].strip()),
                                        dbg_type(pparts[1].strip())
                                        if len(pparts) > 1 else "Any")
            if t == "component":
                return t
            return "%s<%s>" % (t, inner)
        if t in _PRIM_TYPES:
            base = t
        elif t == "{":  # record type
            consume_braces(self.tk)
            base = "{record}"
        else:
            raise WsirError("unexpected type token %r" % t)
        while self.tk.at_punct("["):
            self.tk.take()
            self.tk.expect("]")
            base += "[]"
        return base

    def parse_operand(self):
        t = self.tk.peek()
        if t and t.startswith("%"):
            name = self.tk.take()[1:]
            port = None
            if self.tk.at_punct("."):
                self.tk.take()
                port = self.parse_port_name()
            return ("ref", name, port)
        return ("lit", parse_literal(self.tk), None)

    def parse_attrs(self, props):
        self.tk.expect("{")
        while not self.tk.at_punct("}"):
            if self.tk.at_punct(","):
                self.tk.take()
                continue
            key = self.parse_port_name()
            if self.tk.at_punct("="):
                self.tk.take()
                t = self.tk.peek()
                if t and t.startswith("%"):
                    props[_ATTR_KEY.get(key, key)] = \
                        ("raw", self.tk.take()[1:])
                elif t is not None and (t[0].isalpha() or t[0] == "_") \
                        and not _lit_start(self.tk):
                    # a bare word value is a string (`side = left`)
                    props[_ATTR_KEY.get(key, key)] = ("str", self.tk.take())
                else:
                    props[_ATTR_KEY.get(key, key)] = \
                        _propval(parse_literal(self.tk))
            else:
                props[_ATTR_KEY.get(key, key)] = ("bool", True)
        self.tk.expect("}")

    def parse_metas(self):
        """metadata + loc; returns an explicit !id or None."""
        explicit = None
        tk = self.tk
        while True:
            t = tk.peek()
            if t == "loc":
                tk.take()
                tk.expect("(")
                consume_parens(tk)
                continue
            if not (t and t.startswith("!")):
                return explicit
            # Module metadata ends the item: `!3 = !scope(...)` and the
            # `!inputs`/`!outputs`/`!wire_order` lists are module-level, and
            # a chip body's own list follows its last node.
            if (t[1:].isdigit()
                    or t in ("!inputs", "!outputs", "!wire_order")):
                return explicit
            mt = tk.take()
            if mt == "!id":
                explicit = int(tk.take())
            elif mt in ("!scope", "!chain"):
                tk.take()
            elif mt == "!chip":
                tk.take()
            elif mt in ("!label", "!color", "!material", "!layout_after"):
                tk.expect("(")
                consume_parens(tk)
            elif mt in ("!kind", "!note"):
                tk.take()
            else:
                raise WsirError("unknown metadata %r" % mt)

    def parse_sig(self):
        """':' (ins) '->' (outs) -> [in, out], old type spellings."""
        self.tk.expect(":")
        sides = []
        for which in ("in", "out"):
            side = []
            self.tk.expect("(")
            if self.tk.at_punct("->") and which == "in":
                pass                       # empty input list
            elif not self.tk.at_punct(")"):
                while True:
                    name = self.parse_port_name()
                    self.tk.expect(":")
                    side.append((name, dbg_type(self.parse_type())))
                    if self.tk.at_punct(","):
                        self.tk.take()
                        continue
                    break
            self.tk.expect(")")
            sides.append(side)
            if which == "in":
                self.tk.expect("->")
        return sides


def _lit_start(tk):
    t = tk.peek()
    return t is not None and (
        re.match(r"^(-?\d|\"|true$|false$|nan$|inf|-inf|-nan|vec|rot|quat"
                 r"|lrgba|\#|\[|map|rec|asset|prefab)", t) is not None)


def _is_class_start(tok):
    return (tok is not None and (tok[0].isalpha() or tok[0] == "_")
            and tok not in _PRIM_TYPES)


_TYPE_STARTERS = set(_PRIM_TYPES) | {
    "*", "map", "union", "tuple", "enum", "component", "param", "array",
    "outputs",
}


def _type_start(tok):
    """Does this token open a type?  A ref type starts with `*`, so a chip
    body's `in *int(%total.VarRef)` pin is a type with no class and no
    operand name to speak of -- the class-vs-type test has to see that."""
    return tok in _TYPE_STARTERS or tok == "{"


def _pin_ports(cls_tok, ty):
    """Classes/ports for `in`/`out` pin nodes."""
    t = dbg_type(ty) if ty else "Any"
    if "MicrochipInput" in cls_tok:
        return "BrickComponentType_Internal_MicrochipInput", \
            [("RER_Input", t)], [("RER_Output", t)]
    if "MicrochipOutput" in cls_tok:
        return "BrickComponentType_Internal_MicrochipOutput", \
            [("RER_Input", t)], [("RER_Output", t)]
    full = _new_full_class(old_class(cls_tok))
    if full:
        ent = _inventory()[full]
        return cls_tok, \
            [(n, dbg_type(ty2)) for n, ty2 in ent["in"]], \
            [(n, dbg_type(ty2)) for n, ty2 in ent["out"]]
    return cls_tok, [("RER_Input", t)], [("RER_Output", t)]


def _gate_ports(cls_tok):
    """Pin/pout for gates printed without a signature."""
    core = cls_tok
    for pre in ("BrickComponentType_", "Component_"):
        if core.startswith(pre):
            core = core[len(pre):]
            break
    if core == "Var":
        return [], [("Value", "Any"), ("VarRef", "Any")]
    if core == "ArrayVar":
        return [], [("ArrayVarRef", "Any")]
    if core == "MapVar":
        return [], [("MapVarRef", "Any")]
    if core == "_Literal":
        return [], [("Output", "Any")]
    full = _new_full_class(cls_tok)
    if full and full in _inventory():
        ent = _inventory()[full]
        return ([(n, dbg_type(ty)) for n, ty in ent["in"]],
                [(n, dbg_type(ty)) for n, ty in ent["out"]])
    return [], []


def _module_meta(tk):
    t = tk.take()  # !3 / !inputs / !outputs / !wire_order
    if t[1:].isdigit():
        tk.expect("=")
        tk.expect("!scope")
        tk.expect("(")
        consume_parens(tk)
        return
    if t in ("!inputs", "!outputs"):
        tk.expect("(")
        if not tk.at_punct(")"):
            while True:
                tk.take()
                if tk.at_punct(","):
                    tk.take()
                    continue
                break
        tk.expect(")")
        return
    if t == "!wire_order":
        tk.expect("(")
        if not tk.at_punct(")"):
            consume_parens(tk)
            return
        tk.expect(")")
        return
    raise WsirError("unknown module metadata %r" % t)


def _parse_item(p, mod, add):
    tk = p.tk
    output_form = False
    if tk.at_punct("out"):
        tk.take()
        output_form = True
    vname = tk.take()[1:]

    if output_form:
        # `out %name [Class] [type] [= operand] tail`
        cls_tok = "Internal_MicrochipOutput"
        ty = None
        props = {}
        pin, pout = [], []
        sig = None
        if _is_class_start(tk.peek()) and tk.peek() != "loc":
            cls_tok = tk.take()
        if _type_start(tk.peek()):
            ty = p.parse_type()
        if tk.at_punct("="):
            tk.take()
            p.wire_operand(p.parse_operand(), ("out", vname), "RER_Input",
                           props)
        if tk.at_punct("{"):
            p.parse_attrs(props)
        if tk.at_punct(":"):
            sig = p.parse_sig()
        explicit = p.parse_metas()
        cls, pin, pout = _pin_ports(cls_tok, ty)
        if sig:
            pin, pout = sig
        if props.get("PortLabel") is None and "nolabel" not in props:
            props.setdefault("PortLabel", ("raw", vname))
        props.pop("nolabel", None)
        nid = p.node_id_for(vname, explicit)
        add(nid, "Output", old_class(cls_tok), props, pin, pout)
        return

    tk.expect("=")
    rhs = tk.take()
    props = {}
    explicit = None
    pin, pout = [], []
    sig = None

    if rhs == "in":
        cls_tok = "Internal_MicrochipInput"
        ty = None
        if _is_class_start(tk.peek()) and tk.peek() != "loc":
            cls_tok = tk.take()
        if _type_start(tk.peek()):
            ty = p.parse_type()
        if tk.at_punct("("):
            tk.take()
            if not tk.at_punct(")"):
                # `in 'T' (operand)` or `in 'T' (Port: operand)`.  The port
                # name is a bare word; a `%ref` and a literal are NOT, so
                # test the first character rather than equality -- the ref
                # token is `%total`, not `%`.
                nxt = tk.peek()
                named = (nxt is not None and nxt != "%"
                         and not nxt.startswith("%")
                         and not _lit_start(tk)
                         and (nxt[0].isalpha() or nxt[0] == "_"
                              or nxt.startswith('"')))
                if named:
                    p.parse_port_name()
                    if tk.at_punct(":"):
                        tk.take()
                p.wire_operand(p.parse_operand(), ("in", vname), "RER_Input",
                               props)
            tk.expect(")")
        if tk.at_punct("{"):
            p.parse_attrs(props)
        if tk.at_punct(":"):
            sig = p.parse_sig()
        explicit = p.parse_metas()
        cls, pin, pout = _pin_ports(cls_tok, ty)
        if sig:
            pin, pout = sig
        if props.get("PortLabel") is None and "nolabel" not in props:
            props.setdefault("PortLabel", ("raw", vname))
        props.pop("nolabel", None)
        nid = p.node_id_for(vname, explicit)
        add(nid, "Input", old_class(cls_tok), props, pin, pout)
        return

    if rhs == "chip":
        cls_tok = None
        body_name = None
        if _is_class_start(tk.peek()) and tk.peek() != "loc":
            cls_tok = tk.take()
        if tk.peek() and tk.peek().startswith("@"):
            body_name = tk.take()[1:]
            if body_name.startswith('"'):
                body_name = body_name[1:-1]
        operands = []
        if tk.at_punct("("):
            tk.take()
            while not tk.at_punct(")"):
                if tk.at_punct(","):
                    tk.take()
                    continue
                port = p.parse_port_name()
                tk.expect(":")
                operands.append((port, p.parse_operand()))
            tk.expect(")")
        if tk.at_punct(":"):
            sig = p.parse_sig()
        explicit = p.parse_metas()
        nid = p.node_id_for(vname, explicit)
        for (port, op) in operands:
            p.wire_operand(op, nid, port, props)
        # A chip's '{' opens its BODY, never an attribute list.  Reading it
        # as attributes only worked while metadata happened to sit between
        # the chip's name and the brace; a chip with no metadata there (a
        # nested call inside another chip's body, as `lua.ws` has) had its
        # whole body eaten as props, and the parser then tripped over the
        # body's own first declaration.
        _parse_module_body(p, nid, body_name or "_anon_%s" % vname)
        if tk.at_punct("loc"):                       # loc follows the body
            tk.take()
            tk.expect("(")
            consume_parens(tk)
        # Metadata can also follow the body (`} loc(...) !scope !4`), so
        # take it here too and let an explicit `!id` from either side win.
        after = p.parse_metas()
        if after is not None and explicit is None:
            explicit = after
            nid = p.node_id_for(vname, explicit)
            for (port, op) in operands:
                p.wire_operand(op, nid, port, props)
        add(nid, "Chip", old_class(cls_tok or "Component_Internal_Microchip"),
            props, sig[0] if sig else [], sig[1] if sig else [])
        mod["nchips"] += 1
        return

    # plain gate / declaration
    cls_tok = rhs
    operands = []
    if tk.at_punct("("):
        tk.take()
        while not tk.at_punct(")"):
            if tk.at_punct(","):
                tk.take()
                continue
            port = p.parse_port_name()
            tk.expect(":")
            operands.append((port, p.parse_operand()))
        tk.expect(")")
    if tk.at_punct("{"):
        p.parse_attrs(props)
    if tk.at_punct(":"):
        sig = p.parse_sig()
    explicit = p.parse_metas()
    nid = p.node_id_for(vname, explicit)
    pin, pout = sig if sig else _gate_ports(cls_tok)
    add(nid, "Gate", old_class(cls_tok), props, pin, pout)
    for (port, op) in operands:
        p.wire_operand(op, nid, port, props)


def _parse_module_body(p, parent, name):
    mod = {"name": name, "parent": parent, "nodes": {}, "wires": [],
           "nchips": 0}
    p.mods.append(mod)

    def add(nid, kind, cls, nprops, n_in, n_out):
        from irdump import Node
        if nid in mod["nodes"]:
            raise WsirError("duplicate node id %d" % nid)
        mod["nodes"][nid] = Node(nid, kind, cls, nprops, n_in, n_out)
        p.idmod[nid] = mod
        p.node_by_id[nid] = mod["nodes"][nid]

    p.tk.expect("{")
    while True:
        t = p.tk.peek()
        if t == "}":
            p.tk.take()
            break
        if t is None:
            raise WsirError("EOF in module body")
        if t.startswith("!") and (t[1:].isdigit()
                                  or t in ("!inputs", "!outputs",
                                           "!wire_order")):
            _module_meta(p.tk)
            continue
        if t.startswith("%"):
            _parse_item(p, mod, add)
            continue
        if t == "out":
            _parse_item(p, mod, add)
            continue
        raise WsirError("unexpected token in module body: %r" % t)
    return mod


def _default_out_port(node):
    """The output port a bare `%name` reference stands for.

    A bare reference means "the value this node produces".  Most nodes
    have one output and there is nothing to decide; the ones with more
    are the exec gates, whose value output comes first and whose exec
    output is only ever named explicitly (`%x.ExecOut`) because a chain
    step names it to say which branch it is.  So a bare ref to a
    multi-output node takes the first output that is not an exec port,
    and the first output at all when they all are.
    """
    ports = node.pout
    if len(ports) == 1:
        return ports[0][0]
    if len(ports) > 1:
        for name, ty in ports:
            if str(ty).lower() != "exec":
                return name
        return ports[0][0]
    raise WsirError("bare ref to node %s with no outputs" % node.id)


def parse_program(text):
    tk = _Toks(tokenize(text))
    while tk.peek() != "module":
        if tk.at_end():
            raise WsirError("no module in dump")
        t = tk.take()
        if t in ("!source", "!comment"):
            tk.expect("(")
            consume_parens(tk)
            continue
        if t == "=":
            continue
        if tk.at_punct("("):
            consume_parens(tk)
            continue
        # directive name/value token: skipped
    p = _Parser(tk, id_floor=_max_dumped_id(text))
    p.tk.take()                       # 'module'
    modname = p.tk.take()[1:].strip('"')
    _parse_module_body(p, None, modname)
    _resolve_wires(p)
    return p.mods


def _max_dumped_id(text):
    """The highest node id the dump itself uses.

    The dump's ids are globally unique, but a node may be declared
    WITHOUT one (`out %_exec_out exec = %3597` -- the compiler names the
    pin and leaves the id to the reader).  Those get an id from the
    parser, and the id must not collide with an id the dump already
    uses: the flat id space the Sim runs in would hold two nodes with one
    id, and the later module's node would shadow the earlier one.  That
    is exactly what happened to `lua.ws`: the `resolveKw_1` body's
    output pin took id 6162, a later module's node was named 6162, and
    the pin vanished -- so the lexer's return never reached its caller
    and the parse stopped after one chunk.
    """
    ids = [0]
    for pat in (r"^\s*%(\d+)\s*=", r"^\s*(?:in|out)\s+%(\d+)\s",
                r"!id\s+(\d+)"):
        for m in re.finditer(pat, text, re.M):
            ids.append(int(m.group(1)))
    return max(ids)


def _resolve_wires(p):
    for m in p.mods:
        m["wires"] = []
    for (src, sport, dst, dport) in p.wires:
        src_id = p.name2id.get(src)
        if src_id is None:
            raise WsirError("wire from unknown node %r" % src)
        if not isinstance(sport, str):
            sport = _default_out_port(p.node_by_id[src_id])
        if isinstance(dst, tuple):
            dst_id = p.name2id.get(dst[1])
            if dst_id is None:
                raise WsirError("wire into unknown %r" % (dst,))
        else:
            dst_id = dst
        owner = p.idmod.get(dst_id, p.mods[0])
        owner["wires"].append((src_id, sport, dst_id, dport))
