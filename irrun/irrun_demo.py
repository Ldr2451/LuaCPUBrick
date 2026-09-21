"""Compare IR runner output with model output."""
import sys, os
sys.path.insert(0, 'tinylua')
sys.path.insert(0, 'tinylua/irrun')
from irdump import dump_source
from irgraph import Graph, Wire
from irsims import Sim
import lua_model as m

WS_PATH = 'C:\\Users\\Alessandro\\Documents\\New OpenCode Project\\tinylua\\lua.ws'

# Run model
model_result = m.run_model(open('tinylua/demo.lua').read(),
    inputs=[3.0, 1.0, 4.0, 1.5],
    sinputs={0: 'foo', 1: 'bar'},
    vec=(1.0, 2.0, 3.0),
    col=(0.5, 0.25, 0.125, 1.0),
    inarr=[10.0, 20.0, 30.0])
print('=== MODEL OUTPUT ===')
print('log: ' + repr(model_result['log'][:200]))
print('outNum: ' + str(model_result['outGlobals'][:4]))
print('outStr: ' + str(model_result['outGlobals'][4:]))
print('result: ' + repr(model_result['result']))
print('err: ' + repr(model_result['err']))

# Run IR sim (same program + inputs as the model call above)
nodes, wires, nchips = dump_source(WS_PATH)
sim = Sim(nodes, [Wire(*w) for w in wires])
sim.inputs = {
    'program': open('tinylua/demo.lua').read(),
    'run': True,
    'inNum0': 3.0, 'inNum1': 1.0, 'inNum2': 4.0, 'inNum3': 1.5,
    'inStr0': 'foo', 'inStr1': 'bar',
    'inVec': (1.0, 2.0, 3.0),
    'inCol': (0.5, 0.25, 0.125, 1.0),
    'inArr': [10.0, 20.0, 30.0],
}
result = sim.run(max_ticks=6000)
print('\n=== IR RUNNER OUTPUT ===')
print('halted: ' + str(result['halted']))
print('tick: ' + str(sim.tick))
print('log: ' + repr(result['log'][:200]))
og = result['outGlobals']
print('outNum0: ' + str(og.get('outNum0')))
print('outNum1: ' + str(og.get('outNum1')))
print('outNum2: ' + str(og.get('outNum2')))
print('outNum3: ' + str(og.get('outNum3')))
print('outStr0: ' + repr(og.get('outStr0')))
print('outStr1: ' + repr(og.get('outStr1')))
print('result: ' + repr(og.get('result')))
print('err: ' + repr(og.get('err')))
print('outArr (first 5): ' + str(og.get('outArr', [])[:5]) if og.get('outArr') else 'N/A')
print('outVec: ' + str(og.get('outVec')))
print('outCol: ' + str(og.get('outCol')))
print('busy: ' + repr(og.get('busy')))
print('progOk: ' + str(og.get('progOk')))

# Compare
print('\n=== COMPARISON ===')
match_log = result['log'] == model_result['log']
print('log match: ' + str(match_log))
if not match_log and result['log'] and model_result['log']:
    for i, (a, b) in enumerate(zip(result['log'], model_result['log'])):
        if a != b:
            print('  diff at ' + str(i) + ': ir=' + repr(a) + ' model=' + repr(b))
            break
match_result = result['outGlobals'].get('result') == model_result['result']
print('result match: ' + str(match_result))
match_err = result['outGlobals'].get('err') == model_result['err']
print('err match: ' + str(match_err))
match_num = (og.get('outNum0') == model_result['outGlobals'][0] and
             og.get('outNum1') == model_result['outGlobals'][1] and
             og.get('outNum2') == model_result['outGlobals'][2] and
             og.get('outNum3') == model_result['outGlobals'][3])
print('outNum match: ' + str(match_num))
match_str = (og.get('outStr0') == model_result['outGlobals'][4] and
             og.get('outStr1') == model_result['outGlobals'][5])
print('outStr match: ' + str(match_str))
