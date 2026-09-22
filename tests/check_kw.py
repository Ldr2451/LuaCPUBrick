import sys, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
TINYLUA = os.path.dirname(HERE)
sys.path.insert(0, TINYLUA)
import spec as m
WS = open(os.path.join(TINYLUA, 'lua.ws'), encoding='utf-8').read()
model_kw = set(m.KEYWORDS)
i = WS.index('mod resolveKw(')
i = WS.index('{', i)
depth, j = 0, i
while True:
    if WS[j] == '{': depth += 1
    elif WS[j] == '}':
        depth -= 1
        if depth == 0: break
    j += 1
body = WS[i:j+1]
ws_kw = set(re.findall(r'n == "(\w+)"', body))
print('model-only:', sorted(model_kw - ws_kw))
print('ws-only:', sorted(ws_kw - model_kw))
