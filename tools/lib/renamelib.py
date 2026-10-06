"""Rename chunk-private locals in a Lua piece, deterministically.

The masters in lib/ are the source of truth and stay readable; what ships in
lua.ws is minified.  libconst.py already strips comments, indentation and blank
lines; this renames locals, which is the remaining bulk (~15-25% of characters).

Rules, each with the reason it is safe:

- Only names DECLARED in the chunk are renamed: `local x`, `local function f`,
  function parameters, numeric/generic for variables.  Anything else (globals,
  builtins, _s/_m/_pat gates) is untouched by construction.
- A name starting with `_` is never renamed: `_tonum_hex` is defined in one
  piece and called from another, and the pieces are minified separately, so a
  renamed definition would stop resolving.
- One mapping for the whole chunk: an outer and an inner `local x` take the
  same new name, which preserves shadowing exactly (alpha-renaming).
- A use BEFORE the first declaration of that name refuses the rename: `x = 1`
  before any `local x` is the global x, and renaming it would corrupt the
  program.  Resolution is scope-aware (function boundaries, params, upvalues);
  `local x = ...x...` and `for i = <uses i>` are refused separately, because
  the right side evaluates before the new variable exists.
- `{key = ...}` at brace depth is never renamed even if a local shares the
  spelling: constructor keys are not variables.
- Uses after `.` or `:` are fields/methods, never renamed.
- Generated names (a..z, aa..az, ...) skip every identifier already in the
  chunk, so no new name can collide.  Deterministic: declaration order decides.

Anything ambiguous refuses loudly (ValueError) instead of guessing, because a
piece that minifies wrong fails SILENTLY -- every function in it stops
answering with no message.  The suite after reinstalling everything is the
proof; there is no cheaper one.
"""
import re

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}

TOKEN = re.compile(r"""
    (?P<comment>--\[(=*)\[.*?\]\2\])   # long comment
  | (?P<strlong>\[(=*)\[.*?\2\])       # long string
  | (?P<commentline>--[^\n]*)          # short comment
  | (?P<str>'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")  # short string
  | (?P<num>\b\d[\w.xXpP+-]*)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<other>.)
""", re.VERBOSE | re.DOTALL)


def tokenize(src):
    """(kind, text) list.  Anything unrecognized is `other`, one char."""
    out = []
    pos = 0
    while pos < len(src):
        m = TOKEN.match(src, pos)
        assert m, "unreachable"
        for kind in ("comment", "strlong", "commentline", "str", "num",
                     "ident", "other"):
            t = m.group(kind)
            if t is not None:
                out.append((kind, t))
                break
        pos = m.end()
    return out


def _fresh_names(used, n):
    """n deterministic short names, none in `used`, none a keyword."""
    out = []
    i = 0
    while len(out) < n:
        if i < 26:
            cand = chr(ord("a") + i)
        else:
            cand = chr(ord("a") + (i - 26) // 26) + chr(
                ord("a") + (i - 26) % 26)
        i += 1
        if cand in used or cand in KEYWORDS:
            continue
        out.append(cand)
    return out


def _is_ws(tok):
    return tok[0] == "other" and tok[1].strip() == ""


def _skip_ws(toks, j):
    while j < len(toks) and (_is_ws(toks[j])
                             or toks[j][0] in ("comment", "commentline")):
        j += 1
    return j


def _scopes(toks):
    """Every block span: (kind, start, end_exclusive), functions carry params.

    Resolution needs all of them, not just functions: a `local` inside an
    if-block must not capture a use after the block ends.  The until-condition
    belongs to its repeat span (in Lua it sees the body's locals), so a repeat
    runs to the end of the until line.  Strings and comments are single tokens,
    so an `end` inside one cannot confuse the count.
    """
    OPEN = {"function", "if", "for", "while", "do", "repeat"}
    spans = []
    stack = []          # (kind, start_idx)
    i = 0
    n = len(toks)
    while i < n:
        kind, text = toks[i]
        if kind == "ident" and text in OPEN:
            # `for...do` and `while...do` are ONE block: the `do` belongs to
            # the for/while, so only a bare `do...end` opens here.
            if not (text == "do" and stack and stack[-1][0] in (
                    "for", "while")):
                stack.append((text, i))
            i += 1
            continue
        if kind == "ident" and text in ("end", "until") and stack:
            opener, start = stack.pop()
            end = i
            if opener == "repeat" and text == "until":
                j = i + 1
                while j < n and toks[j] != ("other", "\n"):
                    j += 1
                end = j
            params = _func_params(toks, start) if opener == "function" \
                else {}
            spans.append({"kind": opener, "start": start, "end": end,
                          "params": dict(params)})
            i += 1
            continue
        i += 1
    if stack:
        raise ValueError("unclosed block starting at token %d" % stack[-1][1])
    for s in spans:
        best = None
        for t in spans:
            if t is s:
                continue
            if t["start"] < s["start"] and s["end"] <= t["end"] and (
                    best is None or t["start"] > best["start"]):
                best = t
        s["parent"] = best
    return spans


def _scope_at(spans, idx):
    """Innermost span containing idx, or None for the chunk."""
    best = None
    for s in spans:
        if s["start"] <= idx < s["end"] and (
                best is None or s["start"] > best["start"]):
            best = s
    return best


def _func_params(toks, func_idx):
    """Parameter names of the function opening at func_idx."""
    # find the header's paren pair: first '(' after `function [name]`
    j = func_idx + 1
    while j < len(toks):
        if toks[j] == ("other", "("):
            break
        j += 1
    if j >= len(toks):
        return []
    out = []
    j += 1
    while j < len(toks) and toks[j] != ("other", ")"):
        if toks[j][0] == "ident" and toks[j][1] not in KEYWORDS \
                and toks[j][1] != "...":
            out.append((toks[j][1], j))
        j += 1
    return out


def _significant(toks, j, direction=1):
    """Next/previous meaningful token index, skipping whitespace/comments."""
    n = len(toks)
    j += direction
    while 0 <= j < n and (toks[j][0] in ("comment", "commentline")
                          or _is_ws(toks[j])):
        j += direction
    return j if 0 <= j < n else -1


def _is_field_use(toks, idx):
    """An occurrence preceded by a SINGLE dot/colon is a field/method.

    `..` is two dot tokens, so concatenation operands are not fields: count
    the run back and only treat exactly-one as the field signal.
    """
    p = _significant(toks, idx, -1)
    if not (0 <= p and toks[p][1] in (".", ":")):
        return False
    if toks[p][1] != ".":
        return True
    q = _significant(toks, p, -1)
    return not (0 <= q and toks[q] == ("other", "."))


# Tokens that can continue an expression: binary/unary operators and commas.
_CONTINUE = {".", "..", "...", "+", "-", "*", "/", "//", "%", "^", "#", "~",
             "and", "or", "==", "~=", "<=", ">=", "<", ">", ","}
# Openers that increase nesting depth.
_OPENERS = {"(", "{", "["}
# Tokens that can START an expression operand.
_VALUES = {"ident", "num", "str", "strlong"}


def _region_end(toks, start, spans):
    """End of a local-statement initializer list, starting just after `=`.

    This is an EXPRESSION scan, not a line rule: a piece puts whole statements
    on one line (`local t = {...} t.n = n return t`), so a line rule saw the
    next statement's names as part of the initializer and refused real pieces.
    A token at depth 0 continues the expression when it is an operator or
    comma, or an operand directly after one; anything else (`return`, `end`,
    `if`, `;`, a newline, a name after a complete value) ends it.

    A `function` operand is the one case that needs its body: `local f =
    function() return f end` binds f outside the body, so the body counts as
    the region.  Its end comes from `_scopes`, which already balances
    if/for/while/repeat correctly -- counting only `function`/`end` here
    returned the first `end` in the body and jumped over the statements
    between, which silently lost their declarations.
    """
    n = len(toks)
    by_start = {s["start"]: s for s in spans}
    j = _skip_ws(toks, start)
    if j < n and toks[j] == ("ident", "function"):
        span = by_start.get(j)
        return span["end"] if span else n
    depth = 0
    prev = "op"        # the `=` we started after
    k = start
    while k < n:
        # whitespace and comments are their own tokens and are not part of
        # the expression, so they neither continue nor end it
        k = _skip_ws(toks, k)
        if k >= n:
            break
        kind, text = toks[k]
        if kind == "other":
            if text in _OPENERS:
                depth += 1
                prev = "op"
                k += 1
                continue
            if text in ")]}":
                depth -= 1
                if depth < 0:
                    return k        # ran off the end of the statement
                prev = "value"
                k += 1
                continue
            if depth > 0 or text in _CONTINUE:
                prev = "op"
                k += 1
                continue
            return k                # `;`, newline, a stray `)`
        # ident / num / str.  A KEYWORD that is not an operator ends the
        # statement (`return`, `end`, `if`, `then`, ...); a plain name is an
        # operand and continues when it follows an operator, which is the
        # first token after `=` always is.
        if kind == "ident" and text in KEYWORDS and text not in _CONTINUE:
            return k
        if depth > 0 or prev == "op":
            prev = "value"
            k += 1
            continue
        return k
    return n


def _for_bounds_end(toks, start):
    """End of a numeric `for`'s bounds / a generic `for`'s iterator list.

    Runs to the loop's own `do`, counting only parens: the bounds are
    expressions, not blocks, so block keywords inside them must not confuse the
    count -- `for i = 1, n do ... end` has exactly one `do` at depth 0.
    """
    n = len(toks)
    k = start
    pd = 0
    while k < n:
        if toks[k] == ("other", "("):
            pd += 1
        elif toks[k] == ("other", ")"):
            pd = max(0, pd - 1)
        elif toks[k][0] == "ident" and toks[k][1] == "do" and pd == 0:
            break
        k += 1
    return k


def rename_names(src):
    toks = tokenize(src)
    # identifier texts in order, with positions, skipping strings/comments
    idents = [(i, t) for i, (k, t) in enumerate(toks) if k == "ident"]
    used = {t for _, t in idents}
    spans = _scopes(toks)

    # 1. collect declarations: (name, tok_index, scope, blind).
    #
    #   scope: the block the DECLARATION belongs to.  It comes from the
    #     KEYWORD, not the name token -- `local function f` binds f in the
    #     ENCLOSING scope while the token sits inside the function span, and
    #     scoping by name made every later use look global.  Params take the
    #     function's own span; a `for` takes the keyword's, which is its own.
    #
    #   blind: the initializer / bounds region where this declaration is NOT
    #     yet visible, because the right side evaluates before the variable
    #     exists.  This is where `local x = x + 1`, `local a, b = b, a`,
    #     `for i = i, 10` and `local f = function() return f end` are caught
    #     -- all by ONE rule (see resolve), so the check cannot disagree with
    #     the renaming it guards.  All declarators in a `local` share the
    #     region, which is what `local a, b = b, a` means.
    decls = []
    depth = 0
    i = 0
    while i < len(toks):
        kind, text = toks[i]
        if kind == "other":
            if text == "{":
                depth += 1
            elif text == "}":
                depth = max(0, depth - 1)
            i += 1
            continue
        if kind != "ident":
            i += 1
            continue
        if text == "local":
            kw_scope = _scope_at(spans, i)
            j = _skip_ws(toks, i + 1)
            if j < len(toks) and toks[j] == ("ident", "function"):
                j = _skip_ws(toks, j + 1)
                if j < len(toks) and toks[j][0] == "ident":
                    # `local function f` has no initializer: f exists at once
                    decls.append((toks[j][1], j, kw_scope, None))
                    i = j + 1
                    continue
            # local a, b = ... : names until = or anything else
            j = _skip_ws(toks, i + 1)
            first = j
            while j < len(toks):
                if toks[j][0] == "ident" and toks[j][1] not in KEYWORDS:
                    j = _skip_ws(toks, j + 1)
                    if j < len(toks) and toks[j] == ("other", ","):
                        j = _skip_ws(toks, j + 1)
                        continue
                    break
                break
            blind = None
            if j < len(toks) and toks[j] == ("other", "="):
                end = _region_end(toks, j + 1, spans)
                blind = (j + 1, end)
                j = end
            for k in range(first, j):
                if toks[k][0] == "ident" and toks[k][1] not in KEYWORDS \
                        and (not blind or not (blind[0] <= k < blind[1])):
                    decls.append((toks[k][1], k, kw_scope, blind))
            i = j
            continue
        if text == "function":
            # function name?(params): skip optional dotted name, take params
            j = _skip_ws(toks, i + 1)
            while j < len(toks) and (
                    toks[j][0] == "ident" or toks[j] == ("other", ".")
                    or toks[j] == ("other", ":")):
                # a `(` ends the name: it opens the parameter list
                if toks[j] == ("other", "("):
                    break
                j = _skip_ws(toks, j + 1)
            if j < len(toks) and toks[j] == ("other", "("):
                j = _skip_ws(toks, j + 1)
                while j < len(toks) and toks[j] != ("other", ")"):
                    if toks[j][0] == "ident" and toks[j][1] not in KEYWORDS \
                            and toks[j][1] != "...":
                        # a param binds INSIDE its function, whose span starts
                        # at this very `function` token
                        decls.append((toks[j][1], j, _scope_at(spans, i),
                                      None))
                    j += 1
                i = j + 1
                continue
            i += 1
            continue
        if text == "for":
            # for a = ... | for a, b in ...  (the loop's own scope, which is
            # the keyword's scope), and the variables are NOT visible in the
            # bounds or the iterator list
            kw_scope = _scope_at(spans, i)
            j = _skip_ws(toks, i + 1)
            first = j
            while j < len(toks):
                if toks[j][0] == "ident" and toks[j][1] not in KEYWORDS:
                    j = _skip_ws(toks, j + 1)
                    if j < len(toks) and toks[j] == ("other", ","):
                        j = _skip_ws(toks, j + 1)
                        continue
                    break
                break
            end = _for_bounds_end(toks, j)
            blind = (j, end)
            for k in range(first, j):
                if toks[k][0] == "ident" and toks[k][1] not in KEYWORDS:
                    decls.append((toks[k][1], k, kw_scope, blind))
            i = end
            continue
        i += 1

    # order-preserving unique declaration names, minus _-prefixed
    order = []
    for name, _, _, _ in decls:
        if name not in order:
            order.append(name)
    rename = [n for n in order if not n.startswith("_")]
    fresh = _fresh_names(used, len(rename))
    mapping = dict(zip(rename, fresh))

    # Resolve every occurrence to param/local/global.  A use binds to the
    # nearest dominating declaration walking out: function params first at each
    # function level, then declarations earlier in that scope -- and only
    # OUTSIDE that declaration's own initializer (`blind`), which is the single
    # rule that makes `local x = x + 1`, `local a, b = b, a` and `for i = i, 10`
    # resolve to the globals they really are.  A use that reaches the chunk
    # with nothing dominating is a GLOBAL -- and if the name is mapped (it is
    # declared somewhere), renaming it would corrupt the program, so the piece
    # refuses.
    #
    # `scope` is the scope the DECLARATION belongs to (from its keyword), which
    # is not always the scope its name token sits in: `local function f` binds
    # f in the enclosing scope while the token is inside the function.
    by_name = {}
    for name, idx, sc, bl in decls:
        by_name.setdefault(name, []).append((idx, sc, bl))
    decl_idx = {idx for _, idx, _, _ in decls}

    def dominates(didx, dblind, idx):
        """Is this declaration visible to the use at `idx`?

        Three conditions, and dropping any one is a bug that renames a global:
          - it comes earlier in the source,
          - it is not inside its OWN initializer (`blind`), which is what makes
            `local x = x + 1` read the global rather than itself,
          - the caller has already checked the scope.
        """
        if didx >= idx:
            return False
        if dblind is not None and dblind[0] <= idx < dblind[1]:
            return False
        return True

    def resolve(name, idx):
        s = _scope_at(spans, idx)
        while s is not None:
            if name in s["params"]:
                return "param"
            for didx, dsc, dblind in by_name.get(name, []):
                if dsc is s and dominates(didx, dblind, idx):
                    return "local"
            s = s["parent"]
        for didx, dsc, dblind in by_name.get(name, []):
            if dsc is None and dominates(didx, dblind, idx):
                return "local"
        return "global"

    # 2. rewrite, skipping fields/methods, {key =}, strings, keywords.
    # Declarations rewrite unconditionally (they are the binders); any other
    # occurrence rewrites only when it resolves to a param or a local.
    out = list(toks)
    # Where is this token in an EXPRESSION?  Lua has no block braces, so every
    # `{` is a table constructor -- but a constructor may contain a function
    # body, and a function body holds STATEMENTS.  `for i = 1, ...` and
    # `local a, b = ...` inside such a body are not constructor keys, and
    # counting `{` alone renamed `for i` at its use but not at its declaration,
    # which is the worst shape there is: it compiles, and means something else.
    # So a token is in key position only when its nearest enclosing `{` was
    # opened at the SAME function depth the token sits in.  Counting depth
    # alone (`brace > fdepth`) worked at chunk level and failed inside functions:
    # os.date's `*t` table sits in the function (brace 1, fdepth 1), so its
    # `wday = wday` keys renamed to `ak = ak` -- compiling, and meaning
    # something else.  The suite caught it (os-date-table); the comment above
    # did not, because it described the heuristic instead of the rule.
    fdepth = [0] * len(toks)
    for s in spans:
        if s["kind"] != "function":
            continue
        for i in range(s["start"], s["end"]):
            fdepth[i] += 1

    brace = []          # function-depth recorded at each unclosed `{`
    for i, (kind, text) in enumerate(toks):
        if kind == "other":
            if text == "{":
                brace.append(fdepth[i])
            elif text == "}":
                if brace:
                    brace.pop()
            continue
        if kind != "ident" or text not in mapping:
            continue
        # fields/methods (`t.x`, `s:f()`) are not variables.  Concat (`..`)
        # is two dots and must not read as one -- see _is_field_use.
        if _is_field_use(toks, i):
            continue
        # `{key =`: next significant char is a single `=` (not the first `=`
        # of `==`, which is two tokens) and the nearest enclosing `{` opened
        # at this token's own function depth.
        nxt = _significant(toks, i, 1)
        if brace and brace[-1] == fdepth[i] and 0 <= nxt \
                and toks[nxt] == ("other", "="):
            after = _significant(toks, nxt, 1)
            if not (0 <= after and toks[after] == ("other", "=")):
                continue
        if i not in decl_idx and resolve(text, i) == "global":
            # Name the cause, because the two are fixed differently: a use
            # before its declaration is a piece bug, and a use inside its own
            # initializer (`local x = ...x...`, `local a, b = b, a`,
            # `for i = i, 10`) is also a piece bug -- both mean the right side
            # meant the OUTER name, which the fresh one cannot be.
            blind = [b for _, _, b in by_name.get(text, []) if b is not None
                     and b[0] <= i < b[1]]
            if blind:
                raise ValueError(
                    "use of %r at token %d is inside its own declaration's "
                    "initializer, so it means the OUTER %r, not the local"
                    % (text, i, text))
            raise ValueError(
                "use of %r at token %d resolves to the global, but a local "
                "of that name is declared elsewhere" % (text, i))
        out[i] = ("ident", mapping[text])
    return "".join(t for _, t in out)
