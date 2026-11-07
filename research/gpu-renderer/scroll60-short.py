import sys,time,os
rate=float(sys.argv[1]) if len(sys.argv)>1 else 60
lines=open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'text-short.txt'),'rb').read().split(b'\n')
out=os.fdopen(1,'wb',0); t=time.monotonic(); i=0
while True:
    out.write(lines[i%len(lines)]+b'\n'); i+=1
    t+=1/rate; d=t-time.monotonic()
    if d>0: time.sleep(d)
