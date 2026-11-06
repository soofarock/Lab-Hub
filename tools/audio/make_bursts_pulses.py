import numpy as np, wave, json
SR=48000
man={'rate':SR,'bursts':[],'pulses':[]}
def write(name,x):
    pcm=np.clip(np.round(x*32767),-32768,32767).astype('<i2')
    w=wave.open(name,'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes()); w.close()
# 1. sharp-onset noise bursts: octave bands (raised-cosine edges in the FFT domain) + broadband, exponential decay
rng=np.random.default_rng(20261102)
L=int(0.30*SR); t=np.arange(L)/SR
bands=[('1000',707,1414),('2000',1414,2828),('4000',2828,5657),('8000',5657,11314),('16000',11314,22000),('wide',300,20000)]
for tau_ms in (6,25):
    tau=tau_ms/1000
    for name,lo,hi in bands:
        N=1<<20
        X=np.fft.rfft(rng.standard_normal(N)); f=np.fft.rfftfreq(N,1/SR)
        # flat band with half-octave raised-cosine skirts
        g=np.zeros_like(f)
        inb=(f>=lo)&(f<=hi); g[inb]=1
        for edge,side in ((lo,-1),(hi,1)):
            m=(f>0)&(np.abs(np.log2(np.maximum(f,1e-9)/edge))<0.25)&((f<lo) if side<0 else (f>hi))
            g[m]=0.5+0.5*np.cos(np.pi*np.abs(np.log2(f[m]/edge))/0.25)
        g[f>=SR*0.47]=0
        nz=np.fft.irfft(X*g,N)[:L]
        nz/=np.sqrt(np.mean(nz**2))
        att=np.minimum(1,t/0.0007); att=0.5-0.5*np.cos(np.pi*att)     # 0.7 ms raised-cosine attack
        env=att*np.exp(-t/tau)
        end=np.clip((0.30-t)/0.02,0,1)                               # fade out over the last 20 ms
        x=nz*env*end
        x*=0.89/np.abs(x).max()
        fn='burst_%s_t%d.wav'%(name,tau_ms); write(fn,x)
        first=x[:int(0.005*SR)]
        man['bursts'].append({'file':fn,'band_hz':[lo,hi],'decay_ms':tau_ms,'attack_ms':0.7,'length_s':0.30,
            'peak':round(float(np.abs(x).max()),4),'rms_first_5ms':round(float(np.sqrt(np.mean(first**2))),5),
            'rms_scale':'sample = rms_first_5ms * exp(-t/decay) * unit band noise'})
# 2. pulse-phase harmonic bundles: harmonics k1..k2 of the base, 1/k amplitudes, all in cosine phase (one click per period at t=0)
groups=[(2,17,32),(3,33,64),(4,65,128),(5,129,256)]
for base in (110,220):
    for gi,k1,k2 in groups:
        L=SR; t=np.arange(L)/SR
        ks=[k for k in range(k1,k2+1) if k*base<SR*0.45]
        if not ks: continue
        x=np.zeros(L)
        for k in ks: x+=np.cos(2*np.pi*k*base*(t-0.5/base))/k   # click at half a period: the loop seam falls between clicks
        sc=0.95/np.abs(x).max(); x*=sc
        fn='pulse_g%d_%d.wav'%(gi,base); write(fn,x)
        man['pulses'].append({'file':fn,'base_hz':base,'harmonics':[ks[0],ks[-1]],'amp_of_harmonic_k':'%.6g / k'%sc,
            'phase':'cosine about t = 0.5/base: every harmonic peaks there (one click per period, half a period after the loop start)','length_s':1.0,'loops':True,
            'rms':round(float(np.sqrt(np.mean(x**2))),5),'peak':0.95})
json.dump(man,open('bursts_pulses_manifest.json','w'),indent=1)
print(len(man['bursts']),'bursts',len(man['pulses']),'pulses')
for p in man['pulses']: print(p['file'],p['harmonics'])
