import subprocess
LUA = r'C:\Users\Alessandro\AppData\Local\Programs\Lua55\bin\lua55.exe'
tests = [
    ('FOR', 'for i=1,3 do print(i) end'),
    ('FOR', 'for i=1,1 do print(i) end'),
    ('FOR', 'for i=3,1 do print(i) end'),
    ('FOR', 'local s=0; for i=1,3 do s=s+i end; print(s)'),
    ('FOR', 'for i=1,2.5,0.5 do print(i) end'),
    ('FOR', 'for i=1,2 do print(i) end'),
    ('FOR', 'for i=1,2,1 do print(i) end'),
    ('FOR', 'for i=1.0,2.0 do print(i) end'),
    ('FOR', 'for i=1,3,0 do print(i) end'),
    ('FOR', 'for i=1,2,1.5 do print(i) end'),
    ('FOR', 'for i=0.5,2,0.5 do print(i) end'),
    ('FOR', 'for i=3,1,-1 do print(i) end'),
    ('FOR', 'for i=1,3,2 do print(i) end'),
    ('REPEAT', 'local i=0; repeat i=i+1 until i>=3; print(i)'),
    ('REPEAT', 'local s=0; repeat s=s+1 until s>=3; print(s)'),
    ('REPEAT', 'repeat print("a") until true'),
    ('REPEAT', 'repeat until true; print("done")'),
    ('IDIV', 'print(7//2)'),
    ('IDIV', 'print(-7//2)'),
    ('IDIV', 'print(7.5//2)'),
    ('IDIV', 'print(-7.5//2)'),
    ('IDIV', 'print(10//3)'),
    ('IDIV', 'print(10.0//3)'),
    ('IDIV', 'print(0//1)'),
    ('BITWISE', 'print(5&3)'),
    ('BITWISE', 'print(5|3)'),
    ('BITWISE', 'print(5^3)'),
    ('BITWISE', 'print(~0xFF)'),
    ('BITWISE', 'print(1<<3)'),
    ('BITWISE', 'print(16>>2)'),
    ('BITWISE', 'print(5+~3)'),
    ('BITWISE', 'print(1&2|4)'),
]
for tag, src in tests:
    try:
        r = subprocess.run([LUA, '-e', src], capture_output=True, text=True, timeout=5)
        out = r.stdout
        err = r.stderr.strip()
        if out:
            out = out.rstrip('\n')
        print(tag + ': ' + src[:50].ljust(52) + '=> ' + repr(out) + ' err=' + repr(err))
    except Exception as e:
        print(tag + ': ' + src[:50].ljust(52) + '=> ERROR: ' + str(e))
