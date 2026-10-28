import random, struct, uuid
M=(1<<64)-1
K1=(-0x40A7B892E31B1A47)&M
K2=(-0x6B2FB644ECCEEE15)&M
def h_new(b):
    n=len(b); h=n; i=0
    while i+8<=n:
        h=((h^int.from_bytes(b[i:i+8],'little'))*K1)&M
        h^=(h>>29)&0x7FFFFFFFF
        i+=8
    if i<n:
        if n>=8: w=int.from_bytes(b[n-8:],'little')
        elif n>=4: w=int.from_bytes(b[:4],'little')|(int.from_bytes(b[n-4:],'little')<<32)
        else: w=b[0]|(b[n>>1]<<8)|(b[n-1]<<16)
        h=((h^w)*K1)&M; h^=(h>>29)&0x7FFFFFFFF
    h=(h*K2)&M; h^=(h>>32)&0xFFFFFFFF
    return h&0xFFFFFFFFFFFF
def h_old(b):
    h=5381
    for c in b: h=(h*33+c)&0xFFFFFFFFFFFF
    return h
def probes(keys,hf):
    # table size: power of two >= 2*len (load <= 1/2), linear probing; avg probes for successful search
    z=16
    while z<len(keys)*2: z*=2
    t=[None]*z; tot=0; mx=0
    for k in keys:
        i=hf(k)&(z-1); p=1
        while t[i] is not None: i=(i+1)&(z-1); p+=1
        t[i]=k; tot+=p; mx=max(mx,p)
    return tot/len(keys), mx
rnd=random.Random(1)
sets={
 'cat0-19':[f'cat{i}'.encode() for i in range(20)],
 'code0-999':[f'code{i}'.encode() for i in range(1000)],
 'num1e5':[str(i).encode() for i in range(100000)],
 'user_i 20000':[f'user_{i}@example.com'.encode() for i in range(20000)],
 'rand3':[bytes(rnd.randrange(97,123) for _ in range(3)) for _ in range(5000)],
 'uuid':[str(uuid.UUID(int=rnd.getrandbits(128))).encode() for _ in range(20000)],
 'prefix32+i':[(b'x'*32+str(i).encode()) for i in range(20000)],
 'tail8 same-but-7':[bytes([65]*7+[i&255])+bytes([i>>8]) for i in range(30000)],
 'ab single':[bytes([i]) for i in range(256)],
 'two bytes':[bytes([i,j]) for i in range(256) for j in range(64)],
}
for name,ks in sets.items():
    ks=list(dict.fromkeys(ks))
    print(f'{name:18s} n={len(ks):6d} new={probes(ks,h_new)} old={probes(ks,h_old)}')
