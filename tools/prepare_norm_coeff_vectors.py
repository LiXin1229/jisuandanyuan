"""Adversarial coefficient vectors, independently computed with Python big integers."""
from pathlib import Path
import random
from live_norm_reference import coefficient
out=Path(__file__).resolve().parents[1]/'build/instance_residual_verified'
rng=random.Random(10102026)
cases=[]
for n in (1200,4800,19200,76800):
    for x in (-128,-1,0,1,127):
        for g,b in ((0,0),(256,0),(-256,128),(32767,-32768),(-32768,32767)):
            cases.append((n,n*x,n*x*x,g,b))
    for _ in range(40):
        lo,hi=sorted((rng.randrange(-128,128),rng.randrange(-128,128)))
        k=rng.randrange(n+1)
        cases.append((n,k*lo+(n-k)*hi,k*lo*lo+(n-k)*hi*hi,rng.randrange(-32768,32768),rng.randrange(-32768,32768)))
words=[]
for n,s,q,g,b in cases:
    a,bb=coefficient(n,s,q,g,b)
    word=0
    for width,value in ((17,n),(25,s),(31,q),(16,g),(16,b),(16,a),(16,bb)):
        word=(word<<width)|(value&((1<<width)-1))
    words.append(f'{word:035x}\n')
out.mkdir(parents=True,exist_ok=True)
(out/'coeff_edge.mem').write_text(''.join(words))
print('COEFFICIENT_EDGE_VECTORS',len(words))
