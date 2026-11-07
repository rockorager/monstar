import sys,time,os
src=sys.argv[1]; n=int(sys.argv[2])
lines=open(src,'rb').read().split(b'\n')
out=os.fdopen(1,'wb',0); t=time.monotonic()
out.write(b'\x1b[?25l')
for i in range(n):
    out.write(lines[i%len(lines)]+b'\n')
    t+=1/60; d=t-time.monotonic()
    if d>0: time.sleep(d)
time.sleep(1000)
