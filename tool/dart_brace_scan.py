import sys

def scan(path):
    src = open(path, encoding='utf-8').read()
    out = []
    i = 0
    n = len(src)
    state = None  # None | "'" | '"' | "'''" | '"""'
    while i < n:
        c = src[i]
        if state is None:
            if src.startswith('//', i):
                j = src.find('\n', i)
                i = n if j < 0 else j
                continue
            if src.startswith('/*', i):
                j = src.find('*/', i + 2)
                i = n if j < 0 else j + 2
                continue
            if c == "'" or c == '"':
                if src.startswith(c * 3, i):
                    state = c * 3
                    i += 3
                    continue
                state = c
                i += 1
                continue
            out.append(c)
            i += 1
        else:
            if len(state) == 3:
                if src.startswith(state, i):
                    state = None
                    i += 3
                    continue
                i += 1
                continue
            if c == '\\':
                i += 2
                continue
            if c == state:
                state = None
            i += 1
    text = ''.join(out)
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    line = 1
    for ch in text:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack:
                print(path, 'EXTRA', ch, 'line', line)
                return False
            op, ln = stack.pop()
            if pairs[op] != ch:
                print(path, 'MISMATCH', op, 'line', ln, '->', ch, 'line', line)
                return False
    if stack:
        print(path, 'UNCLOSED', stack[-5:])
        return False
    print(path, 'OK')
    return True

ok = True
for p in sys.argv[1:]:
    ok = scan(p) and ok
sys.exit(0 if ok else 1)
