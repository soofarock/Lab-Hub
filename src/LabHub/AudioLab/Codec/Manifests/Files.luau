-- Per-sound manifest: every sound uploaded as its own file (name -> asset id). Names match WaveBank.assetName().
-- Each file plays whole and loops (waveforms, bundles, noise, pulses) or plays once (bursts, decaying sines).
-- These are the shared public uploads: everything the Lean profile plays. To play more sounds with the Full profile,
-- upload files from the repo's assets/audio/extra and add a line for each, name = "rbxassetid://<id>" (or put the
-- ids in assets/audio/manifest.csv and run tools/set_audio_ids). The profile's `include` decides which are used.
return {
	-- harmonic bundles
	bundle_g1_110 = "rbxassetid://126080135937297",
	bundle_g1_1760 = "rbxassetid://112591584018174",
	bundle_g1_220 = "rbxassetid://116375649654151",
	bundle_g1_440 = "rbxassetid://119291130382023",
	bundle_g1_880 = "rbxassetid://120455324652395",
	bundle_g2_110 = "rbxassetid://117721665144505",
	bundle_g2_220 = "rbxassetid://122665648435679",
	bundle_g2_440 = "rbxassetid://96917448230515",
	bundle_g2_880 = "rbxassetid://97655840277509",
	bundle_g3_110 = "rbxassetid://76827984936222",
	bundle_g3_220 = "rbxassetid://128094781493384",
	bundle_g3_440 = "rbxassetid://82198426831446",
	-- noise bands
	noise_4_1000 = "rbxassetid://110303817588280",
	noise_6_4000 = "rbxassetid://87542516242891",
	-- waveforms
	wave_pulse12_220 = "rbxassetid://123146940349363",
	wave_pulse12_3520 = "rbxassetid://113073596269722",
	wave_pulse12_55 = "rbxassetid://100961276722182",
	wave_pulse12_880 = "rbxassetid://134001598672531",
	wave_pulse25_220 = "rbxassetid://126788089032842",
	wave_pulse25_3520 = "rbxassetid://96035013808185",
	wave_pulse25_55 = "rbxassetid://89431432321451",
	wave_pulse25_880 = "rbxassetid://133471577902403",
	wave_saw_220 = "rbxassetid://84350880162690",
	wave_saw_3520 = "rbxassetid://99435530246652",
	wave_saw_55 = "rbxassetid://126685646665553",
	wave_saw_880 = "rbxassetid://113481681959668",
	wave_sine_880 = "rbxassetid://132947335843282",
	wave_square_220 = "rbxassetid://74618729036752",
	wave_square_3520 = "rbxassetid://75821235022443",
	wave_square_55 = "rbxassetid://97552010667898",
	wave_square_880 = "rbxassetid://84443109338995",
	wave_triangle_220 = "rbxassetid://117527407348219",
	wave_triangle_3520 = "rbxassetid://76084044165895",
	wave_triangle_55 = "rbxassetid://79894731107796",
	wave_triangle_880 = "rbxassetid://105894563882047",
	-- rough sine: noise centred on 880 Hz, 3% wide (Gaussian), RMS 0.25, a seamless 3.9 s loop. Played next to a voice's
	-- harmonics (at k x f0 speed) for the roughness a steady sine lacks. Part of every profile (Manifests.Core).
	rough_880 = "rbxassetid://94674426451942",
	-- pink noise: equal energy per octave, 20 Hz - 20 kHz, RMS 0.2 (like the band loops), a seamless 3 s loop
	-- The breath / air source of source-filter voices: AudioFilters shape it every block. Part of every
	-- profile (Manifests.Core).
	pink_noise = "rbxassetid://95334229148034",
	-- texture codec (Codec.Texture: short sound effects): packed generic pieces, each after a stretch of silence so a piece can
	-- start at an exact time (layout: Texture.LAYOUT). Tones: 120 gliding / hooked decaying tone shapes; clicks: 45 decaying
	-- octave-noise bursts; beds: noise-band loops; loop: the clean 1 kHz half-octave noise (low-cost mode, block clock). Part of every profile (Manifests.Core).
	-- tex_clicks split (Texture.SplitSeconds.clicks): tex_clicks_01 holds the 500 Hz clicks and the short 1000 Hz ones
	tex_clicks_01 = "rbxassetid://118761322132474",
	-- the higher clicks, made in the 500 Hz band and played faster (Texture.ClickLow); the clicks with no file of their
	-- own play one of these or a tex_clicks_01 click sped up
	tex_clicks_low_03 = "rbxassetid://104655637865150",
	tex_clicks_low_07 = "rbxassetid://87878543158729",
	tex_clicks_low_08 = "rbxassetid://109944716659419",
	tex_clicks_low_09 = "rbxassetid://90856463959806",
	tex_clicks_low_10 = "rbxassetid://83942043379770",
	-- tex_tones split into 15 files under 4.16 s (Texture.SplitSeconds)
	tex_tones_01 = "rbxassetid://119962534585589",
	tex_tones_02 = "rbxassetid://111515195768326",
	tex_tones_03 = "rbxassetid://122851274920320",
	tex_tones_04 = "rbxassetid://96039248553930",
	tex_tones_05 = "rbxassetid://119951115926414",
	tex_tones_06 = "rbxassetid://95676194203789",
	tex_tones_07 = "rbxassetid://98948466353181",
	tex_tones_08 = "rbxassetid://137783884697466",
	tex_tones_09 = "rbxassetid://98632218883626",
	tex_tones_10 = "rbxassetid://130608163943953",
	tex_tones_11 = "rbxassetid://139174547102495",
	tex_tones_12 = "rbxassetid://74215610769758",
	tex_tones_13 = "rbxassetid://103515238911848",
	tex_tones_14 = "rbxassetid://79338612225790",
	tex_tones_15 = "rbxassetid://140364450040616",
	tex_loop = "rbxassetid://133267056062375",
	-- the texture player's bed loops (49 bands in 13 short files: Synth.TexturePlayer)
	tex_beds_01 = "rbxassetid://130069682673735",
	tex_beds_02 = "rbxassetid://123055628973714",
	tex_beds_03 = "rbxassetid://84427586403608",
	tex_beds_04 = "rbxassetid://137058391047407",
	tex_beds_05 = "rbxassetid://81941581486587",
	tex_beds_06 = "rbxassetid://110436864350286",
	tex_beds_07 = "rbxassetid://132202168308628",
	tex_beds_08 = "rbxassetid://104514383460516",
	tex_beds_09 = "rbxassetid://108188885849898",
	tex_beds_10 = "rbxassetid://116925508199754",
	tex_beds_11 = "rbxassetid://79666424286770",
	tex_beds_12 = "rbxassetid://112145914964456",
	tex_beds_13 = "rbxassetid://96488434069423",
}
