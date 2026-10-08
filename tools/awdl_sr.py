import struct, sys, collections
path, src = sys.argv[1], bytes.fromhex(sys.argv[2].replace(':',''))
d = open(path,'rb').read(); E = '<' if d[:4]==b'\xd4\xc3\xb2\xa1' else '>'
pos = 24; vals = collections.Counter()
while pos + 16 <= len(d):
    _,_,incl,_ = struct.unpack(E+'IIII', d[pos:pos+16]); pos += 16
    pkt = d[pos:pos+incl]; pos += incl
    w = pkt[struct.unpack('<H', pkt[2:4])[0]:]
    if len(w) < 40 or w[0] != 0xd0 or w[10:16] != src: continue
    b = w[24:]
    if b[0] != 0x7f or b[1:4] != b'\x00\x17\xf2' or b[4] != 8: continue
    t = b[16:-4]  # strip FCS
    i = 0
    while i + 3 <= len(t):
        ty = t[i]; ln = struct.unpack('<H', t[i+1:i+3])[0]; v = t[i+3:i+3+ln]; i += 3+ln
        if ty == 2: vals[v] += 1
for v, n in vals.most_common(20):
    p = ''.join(chr(c) if 32 <= c < 127 else '.' for c in v)
    print(n, len(v), v.hex()[:120]); print('    ', p)
