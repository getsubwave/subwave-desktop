import argparse,json,os,time
p=argparse.ArgumentParser();p.add_argument('--pid',type=int,required=True);p.add_argument('--seconds',type=int,default=300);p.add_argument('--out',required=True);a=p.parse_args()
hz=os.sysconf('SC_CLK_TCK');page=os.sysconf('SC_PAGE_SIZE');start=time.monotonic();rows=[]
def processes():
 d={}
 for e in os.scandir('/proc'):
  if not e.name.isdigit():continue
  try:
   raw=open(e.path+'/stat').read();tail=raw[raw.rfind(')')+2:].split()
   d[int(e.name)]={'ppid':int(tail[1]),'ticks':int(tail[11])+int(tail[12]),'rss':int(tail[21])*page}
  except (OSError,ValueError,IndexError):pass
 selected={a.pid}
 while True:
  new=selected|{pid for pid,v in d.items() if v['ppid'] in selected}
  if new==selected:break
  selected=new
 return {pid:d[pid] for pid in selected if pid in d}
previous={};last=time.monotonic()
while time.monotonic()-start<a.seconds:
 now=time.monotonic();ps=processes()
 if a.pid not in ps:raise SystemExit('application exited during measurement')
 cpu=sum(max(0,v['ticks']-previous.get(pid,v['ticks'])) for pid,v in ps.items())/hz/max(now-last,.001)*100
 rows.append({'elapsed':round(now-start,3),'cpu_percent_one_core':round(cpu,3),'rss_bytes_sum':sum(v['rss'] for v in ps.values()),'processes':len(ps)})
 previous={pid:v['ticks'] for pid,v in ps.items()};last=now
 time.sleep(1)
result={'duration_seconds':round(time.monotonic()-start,2),'pid':a.pid,'rss_note':'sum of process RSS; shared pages may be counted more than once','samples':rows,'mean_cpu_percent_one_core':sum(x['cpu_percent_one_core'] for x in rows[1:])/max(1,len(rows)-1),'peak_rss_bytes_sum':max(x['rss_bytes_sum'] for x in rows)}
with open(a.out,'w') as f:json.dump(result,f,indent=2)
print(json.dumps({k:v for k,v in result.items() if k!='samples'}))
