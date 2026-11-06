# X5 chain (game-playable): grains (half-octave, crackle above 1 kHz, clean sources, 7/10 ms) + blips
import numpy as np, render as RN, ridges as RG, v4, grain as G, demo as D
R=48000; Dd='../sf_out/demo'; tag='sfx_3_water_01_splash'
def setup():
    G.BANDS=[125*2**(i/2) for i in range(14) if 125*2**(i/2)<=5700]; G.HALF=0.5; G.OVERLAP=2
    G.CRK_RATE.update({'noise_4_1000':2500,'noise_6_4000':10000}); G.CRK_FROM=1000; G.CLEAN=True
    G.LOWPASS=7800; G.MIN_BAND=125; G.G_REAL=0.007; G.G_REAL_LOW=0.010
setup()
def load(tag):
    return RN.readwav(f'{Dd}/{tag}_original.wav')[0][:,0]
def blips_render(ev, n):
    return v4.render(dict(blips=ev['blips'],hits=[],noise=np.zeros((n//1024+3,len(v4.CENTERS))),crackle={}),n,nyq=24000)
def chain(x, blip_ev, tone_for_grains=None):
    n=len(x)
    tr,hop,win=RG.track(x)
    ts=RG.synth(tr,hop,win,n) if tone_for_grains is None else tone_for_grains
    tb=blips_render(blip_ev,n)
    gr=G.encode(x,ts); yg,st=G.render(gr,n)
    return tb+yg, st
if __name__=='__main__':
    x=load(tag); y,st=chain(x, v4.encode(x))
    s=D.score(x,y); print(s, st)
    z=RN.readwav(f'{Dd}/X5_low.wav')[0]; z=z[:,0] if z.ndim>1 else z
    m=min(len(z),len(y)); print('corr with saved X5', np.corrcoef(z[:m],y[:m])[0,1])
