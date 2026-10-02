"""Full gate catalogue for the tick sim.

The WireScript compiler lowers expressions/statement steps to Brick wire-graph
gates.  Every gate class it can emit is implemented here, so a program can never
silently run with a skipped gate (which used to corrupt state: an unmodelled
gate reads as `None`, and a `None` pushed into one of the parallel bytecode
arrays shifts every later operand by one).

Two classes are special:

`_Unsupported`
    NOT a gate.  The compiler emits it as a placeholder when an expression fails
    to lower (an unresolved name, a mis-typed call, a value in an illegal
    context).  On hardware it reads 0 and does nothing, i.e. it is a silent
    miscompile.  `gate_is_placeholder` reports it so callers can fail loudly
    instead of running a wrong circuit.

`_Literal`
    A constant; the sim initialises it from its `Value`/`InitialValue` prop.

Port names below are taken from the game's own inventory
(`crates/wirescript/data/inventory_brdb.json`), so they match the real chip.
"""
from __future__ import annotations

import math
import random
from typing import Any, Callable

# ── class-name helpers ──────────────────────────────────────────────────────

PLACEHOLDER = "_Unsupported"
LITERAL = "_Literal"


def gate_is_placeholder(cls: str) -> bool:
    """True for the compiler's miscompile placeholder (never a real gate)."""
    return cls == PLACEHOLDER or cls.endswith("Pseudo_Unsupported")


def placeholder_nodes(nodes: dict) -> list:
    """Every placeholder node in a dumped graph (nid, class, _bindname)."""
    out = []
    for nid, nd in nodes.items():
        if gate_is_placeholder(nd.cls):
            bind = nd.props.get("_bindname")
            out.append((nid, nd.cls, bind[1] if isinstance(bind, tuple) else bind))
    return out


# Gates whose exec chain is "pass-through" (no value work).
PASSTHRU_EXEC = {
    "BrickComponentType_WireGraph_Exec_ArrayVar_Fill",
    "BrickComponentType_WireGraph_Exec_ArrayVar_Reverse",
    "BrickComponentType_WireGraph_Exec_ArrayVar_Shuffle",
    "BrickComponentType_WireGraph_Exec_ArrayVar_Sort",
    "BrickComponentType_WireGraph_Exec_ArrayVar_SortMultiple",
    "BrickComponentType_WireGraph_Exec_MapVar_GetValues",
}

# ── gate ports (from inventory_brdb.json) ───────────────────────────────────

ARRAY_GATE_PORTS = {
    # class suffix -> (inputs, outputs)
    "Append": (["Exec", "ArrayVarRef", "SourceRef"], ["ExecOut"]),
    "Average": (["Exec", "ArrayVarRef"], ["Value", "ExecOut", "bIsEmpty"]),
    "Clear": (["Exec", "ArrayVarRef"], ["ExecOut"]),
    "CopyFrom": (["Exec", "ArrayVarRef", "SourceRef"], ["ExecOut"]),
    "Fill": (["Value", "Exec", "ArrayVarRef"], ["ExecOut"]),
    "Find": (["Value", "Exec", "ArrayVarRef"], ["Index", "ExecOut", "bFound"]),
    "Get": (["Exec", "ArrayVarRef", "Index"], ["Value", "ExecOut", "bOutOfBounds"]),
    "GetAtIndex": (["Exec", "ArrayVarRef", "Index"], ["Value", "ExecOut", "bOutOfBounds"]),
    "GetLength": (["Exec", "ArrayVarRef"], ["Length", "ExecOut"]),
    "Insert": (["Value", "Exec", "ArrayVarRef", "Index"],
               ["ExecOut", "bOutOfBounds"]),
    "Max": (["Exec", "ArrayVarRef"], ["Value", "ExecOut", "bIsEmpty"]),
    "Min": (["Exec", "ArrayVarRef"], ["Value", "ExecOut", "bIsEmpty"]),
    "Pop": (["Exec", "ArrayVarRef"], ["Value", "ExecOut", "bIsEmpty"]),
    "Push": (["Value", "Exec", "ArrayVarRef"], ["ExecOut"]),
    "RemoveAtIndex": (["Exec", "ArrayVarRef", "Index"],
                      ["ExecOut", "bOutOfBounds"]),
    "Resize": (["Value", "Exec", "ArrayVarRef", "Size"], ["ExecOut"]),
    "Reverse": (["Exec", "ArrayVarRef"], ["ExecOut"]),
    "SetAtIndex": (["Value", "Exec", "ArrayVarRef", "Index"], ["ExecOut"]),
    "Shuffle": (["Exec", "ArrayVarRef"], ["ExecOut"]),
    "Slice": (["Exec", "ArrayVarRef", "Start", "Count", "SourceRef"],
              ["ExecOut", "bOutOfBounds"]),
    "Sort": (["Exec", "ArrayVarRef", "bDescending"], ["ExecOut"]),
    "SortMultiple": (["Exec", "ArrayVarRef", "ArrayVarRef1", "ArrayVarRef2",
                      "ArrayVarRef3", "ArrayVarRef4", "ArrayVarRef5",
                      "ArrayVarRef6", "ArrayVarRef7", "bDescending"], ["ExecOut"]),
    "Sum": (["Exec", "ArrayVarRef"], ["Value", "ExecOut"]),
    "Swap": (["Exec", "ArrayVarRef", "IndexA", "IndexB"],
             ["ExecOut", "bOutOfBounds"]),
}

MAP_GATE_PORTS = {
    "Clear": (["Exec", "MapVarRef"], ["ExecOut"]),
    "CopyFrom": (["Exec", "MapVarRef", "SourceRef"], ["ExecOut"]),
    "Get": (["Exec", "MapVarRef", "Key"], ["Value", "bFound", "ExecOut"]),
    "GetKeys": (["Exec", "MapVarRef", "ArrayVarRef"], ["ExecOut"]),
    "GetLength": (["Exec", "MapVarRef"], ["Length", "ExecOut"]),
    "GetValues": (["Exec", "MapVarRef", "ArrayVarRef"], ["ExecOut"]),
    "Has": (["Exec", "MapVarRef", "Key"], ["bFound", "ExecOut"]),
    "Remove": (["Exec", "MapVarRef", "Key"], ["bFound", "ExecOut"]),
    "Set": (["Exec", "MapVarRef", "Key", "Value"], ["ExecOut"]),
}

MATH_GATE_PORTS = {
    "Abs": (["Input"], ["Output"]),
    "Acos": (["Input"], ["Output"]),
    "Acosh": (["Input"], ["Output"]),
    "Add": (["InputA", "InputB"], ["Output"]),
    "Asin": (["Input"], ["Output"]),
    "Asinh": (["Input"], ["Output"]),
    "Atan": (["Input"], ["Output"]),
    "Atan2": (["X", "Y"], ["Output"]),
    "Atanh": (["Input"], ["Output"]),
    "Blend": (["InputA", "InputB", "Blend"], ["Output"]),
    "Ceil": (["Input"], ["Output"]),
    "Clamp": (["Input", "Min", "Max"], ["Output"]),
    "Cos": (["Input"], ["Output"]),
    "Cosh": (["Input"], ["Output"]),
    "DegreesToRadians": (["Input"], ["Output"]),
    "Divide": (["InputA", "InputB"], ["Output"]),
    "Easing": (["Function", "Direction", "InputA", "InputB", "Blend"], ["Output"]),
    "Exp": (["Input"], ["Output"]),
    "Floor": (["Input"], ["Output"]),
    "Ln": (["Input"], ["Output"]),
    "LogBase": (["Input", "Base"], ["Output"]),
    "Max": (["InputA", "InputB"], ["Output"]),
    "Min": (["InputA", "InputB"], ["Output"]),
    "Modulo": (["InputA", "InputB"], ["Output"]),
    "ModuloFloored": (["InputA", "InputB"], ["Output"]),
    "Multiply": (["InputA", "InputB"], ["Output"]),
    "Negate": (["Input"], ["Output"]),
    "Pow": (["Input", "Exponent"], ["Output"]),
    "RadiansToDegrees": (["Input"], ["Output"]),
    "Round": (["Input"], ["Output"]),
    "Sgn": (["Input"], ["Output"]),
    "Sign": (["Input"], ["Output"]),
    "Sin": (["Input"], ["Output"]),
    "Sinh": (["Input"], ["Output"]),
    "Sqrt": (["Input"], ["Output"]),
    "Subtract": (["InputA", "InputB"], ["Output"]),
    "Tan": (["Input"], ["Output"]),
    "Tanh": (["Input"], ["Output"]),
    "Trunc": (["Input"], ["Output"]),
}

STRING_GATE_PORTS = {
    "CharacterToCodepoint": (["Input", "Character"], ["Codepoint", "bSuccess"]),
    "CodepointToCharacter": (["Input", "Codepoint"], ["Character", "bSuccess"]),
    "Concatenate": (["InputA", "InputB", "Separator"], ["Output"]),
    "Contains": (["Input", "bCaseSensitive", "Search"], ["Output"]),
    "EndsWith": (["Input", "bCaseSensitive", "Suffix"], ["Output"]),
    "Find": (["Input", "bCaseSensitive", "Search"], ["Output"]),
    "FormatText": (["InputA", "InputB", "FormatString", "InputC", "InputD",
                    "InputE", "InputF", "InputG"], ["Output"]),
    "Length": (["Input"], ["Output"]),
    "ParseInt": (["Input"], ["Value", "bSuccess"]),
    "ParseNumber": (["Input"], ["Value", "bSuccess"]),
    "Replace": (["Input", "bCaseSensitive", "Search", "Replacement"], ["Output"]),
    "Split": (["Input", "bCaseSensitive", "Delimiter"],
              ["Left", "Right", "bFound"]),
    "StartsWith": (["Input", "Prefix", "bCaseSensitive"], ["Output"]),
    "Substring": (["Input", "Start", "Length"], ["Output"]),
    "ToLower": (["Input"], ["Output"]),
    "ToUpper": (["Input"], ["Output"]),
    "Trim": (["Input"], ["Output"]),
}

VECTOR_GATE_PORTS = {
    "MakeColor": (["R", "G", "B", "A"], ["Output"]),
    "MakeColorHex": (["Input"], ["Output"]),
    "MakeColorSRGB": (["Input"], ["Output"]),
    "MakeQuaternion": (["X", "Y", "Z", "W"], ["Output"]),
    "MakeRotation": (["X", "Y", "Z"], ["Output"]),
    "MakeVector": (["X", "Y", "Z"], ["Output"]),
    "SplitColor": (["Input", "Input.B", "Input.G", "Input.R", "Input.A"],
                   ["R", "G", "B", "A"]),
    "SplitQuat": (["Input"], ["X", "Y", "Z", "W"]),
    "SplitVec": (["Input", "Input.X", "Input.Y", "Input.Z"], ["X", "Y", "Z"]),
    "SplitVector": (["Input", "Input.X", "Input.Y", "Input.Z"], ["X", "Y", "Z"]),
}

BITWISE_GATE_PORTS = {
    "AND": (["InputA", "InputB"], ["Output"]),
    "BitCount": (["Input"], ["Output"]),
    "NAND": (["InputA", "InputB"], ["Output"]),
    "NOR": (["InputA", "InputB"], ["Output"]),
    "NOT": (["Input"], ["Output"]),
    "OR": (["InputA", "InputB"], ["Output"]),
    "ShiftLeft": (["InputA", "InputB"], ["Output"]),
    "ShiftRight": (["InputA", "InputB"], ["Output"]),
    "XOR": (["InputA", "InputB"], ["Output"]),
}


def all_gate_classes() -> set:
    """Every gate class name this module models, as full class strings."""
    out = set()
    for table, prefix in ((ARRAY_GATE_PORTS, "BrickComponentType_WireGraph_Exec_ArrayVar_"),
                          (MAP_GATE_PORTS, "BrickComponentType_WireGraph_Exec_MapVar_"),
                          (MATH_GATE_PORTS, "BrickComponentType_WireGraph_Expr_Math"),
                          (STRING_GATE_PORTS, "BrickComponentType_WireGraph_Expr_String_"),
                          (VECTOR_GATE_PORTS, "BrickComponentType_WireGraph_Expr_"),
                          (BITWISE_GATE_PORTS, "BrickComponentType_WireGraph_Expr_Bitwise")):
        for suffix in table:
            out.add(prefix + suffix)
    out |= {
        "BrickComponentType_WireGraphPseudo_ArrayVar",
        "BrickComponentType_WireGraphPseudo_MapVar",
        "BrickComponentType_WireGraphPseudo_Var",
        "BrickComponentType_WireGraphPseudo_BufferTicks",
        "BrickComponentType_WireGraphPseudo_BufferSeconds",
        "BrickComponentType_WireGraphPseudo_QueueTicks",
        "BrickComponentType_WireGraphPseudo_QueueSeconds",
        "BrickComponentType_WireGraphPseudo_Timer",
        "BrickComponentType_WireGraphPseudo_Tween",
        "BrickComponentType_WireGraphPseudo_Dampen",
        "BrickComponentType_WireGraph_Exec_Branch",
        "BrickComponentType_WireGraph_Exec_Union",
        "BrickComponentType_WireGraph_Exec_Var_Get",
        "BrickComponentType_WireGraph_Exec_Var_Set",
        "BrickComponentType_WireGraph_Exec_Var_Increment",
        "BrickComponentType_WireGraph_Exec_SweepSimple",
        "BrickComponentType_WireGraph_Expr_ChangeDetectorExec",
        "BrickComponentType_WireGraph_Expr_LogicalAND",
        "BrickComponentType_WireGraph_Expr_LogicalOR",
        "BrickComponentType_WireGraph_Expr_LogicalNAND",
        "BrickComponentType_WireGraph_Expr_LogicalNOR",
        "BrickComponentType_WireGraph_Expr_LogicalXOR",
        "BrickComponentType_WireGraph_Expr_LogicalNOT",
        "BrickComponentType_WireGraph_Expr_CompareEqual",
        "BrickComponentType_WireGraph_Expr_CompareNotEqual",
        "BrickComponentType_WireGraph_Expr_CompareGreater",
        "BrickComponentType_WireGraph_Expr_CompareGreaterOrEqual",
        "BrickComponentType_WireGraph_Expr_CompareLess",
        "BrickComponentType_WireGraph_Expr_CompareLessOrEqual",
        "BrickComponentType_WireGraph_Expr_Select",
        "BrickComponentType_WireGraph_DeltaTime",
        "BrickComponentType_WireGraph_ServerUptime",
        "BrickComponentType_Clock",
        "BrickComponentType_Internal_MicrochipInput",
        "BrickComponentType_Internal_MicrochipOutput",
        # A chip call site. Pure structure: it has no ports and no wires, and the
        # call's arguments, its exec trigger and its result all travel on the
        # body's MicrochipInput/MicrochipOutput pins instead (cross-module wires
        # that live in the caller's wire list). So there is nothing to execute
        # here -- listing it says "recognised, does nothing" rather than leaving
        # it unhandled and silently dropping every program that uses a chip.
        "BrickComponentType_Internal_Microchip",
        "BrickComponentType_Internal_ReadBrickGrid",
        LITERAL,
    }
    return out
