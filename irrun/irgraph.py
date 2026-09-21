"""Tiny Lua IR-level simulator.

Reads `wirescript compile --dump-ir-full` output for tinylua/lua.ws,
simulates the exec-chain model every clock tick, and produces the
same observable outputs (out ports, log) that the Python model does.

Gate semantics are taken from the documented IR node definitions:
https://wirescript.brickadia.dev/docs/ir/nodes
"""
from __future__ import annotations

import sys
import re
import os
from dataclasses import dataclass, field
from typing import Any, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from irdump import dump_source, Node

OUT_BRZ = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lua.brz")

# ---------------------------------------------------------------------------
# Literal to Python
# ---------------------------------------------------------------------------

def lit_value(lit: tuple) -> Any:
    kind, v = lit
    return v


def lit_str(lit: tuple) -> str:
    if lit[0] == "str":
        return lit[1]
    return repr(lit[1])


def lit_float(lit: tuple) -> float:
    if lit[0] == "float":
        return lit[1]
    if lit[0] == "int":
        return float(lit[1])
    return 0.0


def lit_int(lit: tuple) -> int:
    if lit[0] == "int":
        return lit[1]
    if lit[0] == "float":
        return int(lit[1])
    return 0


def lit_bool(lit: tuple) -> bool:
    if lit[0] == "bool":
        return lit[1]
    if lit[0] == "int":
        return lit[1] != 0
    if lit[0] == "float":
        return lit[1] != 0.0
    return False


# ---------------------------------------------------------------------------
# Graph build
# ---------------------------------------------------------------------------

@dataclass
class Wire:
    src_id: int
    src_port: str
    dst_id: int
    dst_port: str


@dataclass
class Graph:
    nodes: dict[int, Node]
    wires: list[Wire]
    nchips: int

    @classmethod
    def from_dump(cls, text: str) -> Graph:
        from irdump import parse_dump
        nodes, wires, nchips = parse_dump(text)
        return cls(nodes, [Wire(*w) for w in wires], nchips)

    @classmethod
    def from_file(cls, ws_path: str, brz_out: Optional[str] = None) -> Graph:
        nodes, wires, nchips = dump_source(ws_path, brz_out)
        return cls(nodes, [Wire(*w) for w in wires], nchips)

    def inputs(self) -> list[Wire]:
        return [w for w in self.wires
                if self.nodes[w.dst_id].kind == "Input"]

    def outputs(self) -> list[Wire]:
        return [w for w in self.wires
                if self.nodes[w.dst_id].kind == "Output"]
