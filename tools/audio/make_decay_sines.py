import numpy as np, wave, os, json
RATE=48000; BASES=[55,220,880,3520]; N=11; LEN=7.0; AMP=0.9
MAX_FILE=4.16  # upload files stay under 4.16 s: the long decays (t8..t11) are cut there; the synth re-arms before the end
def tau(n): return 0.025*1.6**(n-1)
man=[]
for b in BASES:
    for n in range(1,N+1):
        T=tau(n); L=min(int(np.ceil(LEN*T*RATE)), int(MAX_FILE*RATE)); t=np.arange(L)/RATE
        x=AMP*np.exp(-t/T)*np.sin(2*np.pi*b*t)
        # last 2 ms fade to exact zero so the loop point is silent
        k=int(0.002*RATE); x[-k:]*=np.linspace(1,0,k)
        pcm=np.round(x*32767).astype('<i2'); name='dsine_%d_t%d'%(b,n)
        w=wave.open('%s.wav'%name,'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(pcm.tobytes()); w.close()
        man.append(dict(name=name,base=b,tau=round(T,6),seconds=round(L/RATE,4)))
json.dump(man,open('decay_manifest.json','w'),indent=1)
print(len(man),'files', sum(m['seconds'] for m in man),'s total')
