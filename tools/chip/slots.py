import re
s = open('lua.ws', encoding='utf-8').read()
for name in ('GTAG_INIT', 'GNUM_INIT'):
    m = re.search(name + r': (?:int|float)\[\] = \[([^\]]*)\]', s)
    vals = [x.strip() for x in m.group(1).split(',')]
    print(name, 'len=', len(vals))
    print('   ', ' '.join('%d:%s' % (i, v) for i, v in enumerate(vals) if i >= 17))
print('declares _s:', 'gDeclare("_s")' in s)
print('const NB:', re.findall(r'const NB = \d+', s))
