import re,subprocess,sys,os,statistics
env=dict(os.environ); 
for kv in sys.argv[2:]: k,v=kv.split('=',1); env[k]=v
names=["wayland configured","vkCreateInstance","enumerate physical","vkCreateDevice","pipeline","atlas+buffers","swapchain","first frame GPU done"]
rows=[]
for i in range(int(sys.argv[1])):
    p=subprocess.run(["timeout","1","./vkgrid/vkgrid","idle"],env=env,capture_output=True,text=True)
    m={a.strip():float(b) for a,b in re.findall(r"mark (.+?)\s+([\d.]+) ms",p.stderr)}
    rows.append([m[names[j+1]]-m[names[j]] for j in range(len(names)-1)]+[m[names[-1]]-m[names[0]]])
lab=["instance","enum_phys","device","pipeline","atlas+bufs","swapchain","first_frame","TOTAL"]
print(" ".join(f"{l}={statistics.median(c):.1f}" for l,c in zip(lab,zip(*rows))))
