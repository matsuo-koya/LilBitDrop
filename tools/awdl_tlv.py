import struct, sys, collections
path, src = sys.argv[1], bytes.fromhex(sys.argv[2].replace(':',''))
d = open(path,'rb').read()
le = d[:4] == b'\xd4\xc3\xb2\xa1'
E = '<' if le else '>'
pos = 24
types = collections.Counter(); samples = {}
nframes = 0
while pos + 16 <= len(d):
    ts, tu, incl, orig = struct.unpack(E+'IIII', d[pos:pos+16]); pos += 16
    pkt = d[pos:pos+incl]; pos += incl
    rtlen = struct.unpack('<H', pkt[2:4])[0]
    w = pkt[rtlen:]
    if len(w) < 24 or w[0] != 0xd0: continue   # action frame
    if w[10:16] != src: continue
    body = w[24:]
    if len(body) < 16 or body[0] != 0x7f or body[1:4] != b'\x00\x17\xf2' or body[4] != 0x08: continue
    nframes += 1
    t = body[16:]
    i = 0
    seen = set()
    while i + 3 <= len(t):
        ty = t[i]; ln = struct.unpack('<H', t[i+1:i+3])[0]
        v = t[i+3:i+3+ln]; i += 3 + ln
        types[ty] += 1
        if ty not in samples: samples[ty] = v
print('frames', nframes)
for ty, n in sorted(types.items()):
    v = samples[ty]
    printable = ''.join(chr(c) if 32 <= c < 127 else '.' for c in v[:80])
    print(f'type {ty:3d} count {n:5d} len {len(v):4d} hex {v[:24].hex()} txt {printable}')
