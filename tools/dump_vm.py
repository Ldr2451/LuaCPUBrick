"""Dump the bytecode (and with --tokens the token stream) a program compiles to.

  python -u tools/dump_vm.py "for k,v in pairs(t) do print(k,v) end"
  python -u tools/dump_vm.py --tokens "print(1)"
  python -u tools/dump_vm.py @prog.lua

An argument of @path reads one program from that file.  A shell that eats the
double quotes out of an argument turns `print("x")` into `print(x)`, which
compiles to something else entirely; the file form cannot be mangled that way.

Builds the chip once per invocation (~6s), so pass several programs at once.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'irrun'))
from irdump import dump_source, resolve_prog
from irsims import Sim, Wire, ChipRunner, _extract

NAMES = {0:'HALT',1:'LOADNIL',2:'LOADNUM',3:'LOADSTR',4:'LOADBOOL',5:'LOADGLOBAL',
         6:'STOREGLOBAL',7:'MOV',8:'ADD',9:'SUB',10:'MUL',11:'DIV',12:'MOD',13:'POW',
         14:'UNM',15:'NOT',16:'CONCAT',17:'EQ',18:'LT',19:'LE',20:'JMP',21:'JMPF',
         22:'JMPT',23:'CALL',24:'RETURN',25:'LOADFUNC',26:'RETURN0',27:'RETURNV',
         28:'NEWTABLE',29:'GETFIELD',30:'SETFIELD',31:'LEN',32:'FORPREP',33:'FORLOOP',
         34:'IDIV',35:'BAND',36:'BOR',37:'BXOR',38:'BNOT',39:'SHL',40:'SHR',
         41:'CALLM',42:'RETURNM'}
# kind 4 is a keyword, identified by its sub code
KWSUBS = {1:'and',2:'break',3:'do',4:'else',5:'elseif',6:'end',7:'false',8:'function',
          9:'if',10:'local',11:'nil',12:'not',13:'or',14:'return',15:'then',16:'true',
          17:'while',18:'for',19:'in',20:'repeat',21:'until',22:'goto'}

def dump(runner, src, tokens=False):
    sim = runner.sim
    runner.reset()
    sim.inputs = {'program': src, 'run': True}
    r = sim.run(max_ticks=int(os.environ.get('PROBE_TICKS', '8000')))
    err = r.get('outGlobals', {}).get('err', '') if r else ''
    labels = {}
    for nid, nd in sim.nodes.items():
        lbl = _extract(nd.props.get('_label', ('raw', '')))
        if isinstance(lbl, str):
            labels[nid] = lbl
    def arr(name):
        for nid, l in labels.items():
            if l == name:
                return sim.arrays.get(nid)
        return None
    print(f"=== {src}")
    print(f"  log={sim.log!r}  err={err!r}")
    if tokens:
        srcv = sim.vars.get(next((n for n, l in labels.items() if l == 'lsrc'),
                                 None))
        print(f"  lsrc={srcv!r}")
        for tk, ts, tv in zip(arr('tk') or [], arr('ts') or [],
                              arr('tt') or []):
            if tk == 4:
                print(f"  tok KW {KWSUBS.get(int(ts), ts)}")
            elif tk == 3:
                print(f"  tok NAME {tv!r}")
            elif tk == 5:
                print(f"  tok PUNCT {int(ts)}")
            else:
                print(f"  tok {int(tk)} {int(ts)} {tv!r}")
    bop, bpa, bpb, bpc = arr('bop'), arr('bpa'), arr('bpb'), arr('bpc')
    if not bop:
        return
    for i in range(len(bop)):
        op = int(bop[i])
        a = int(bpa[i]) if i < len(bpa) else '?'
        b = int(bpb[i]) if i < len(bpb) else '?'
        c = int(bpc[i]) if i < len(bpc) else '?'
        print(f"  [{i:2}] {NAMES.get(op, op):10} a={a} b={b} c={c}")


if __name__ == '__main__':
    tokens = '--tokens' in sys.argv
    srcs = []
    for a in sys.argv[1:]:
        if a == '--tokens':
            continue
        if a.startswith("@"):
            with open(a[1:], encoding="utf-8") as f:
                srcs.append(f.read())
        else:
            srcs.append(resolve_prog(a, ROOT))
    runner = ChipRunner(os.path.join(ROOT, 'lua.ws'))
    for src in srcs:
        dump(runner, src, tokens=tokens)
