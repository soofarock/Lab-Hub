--!native
--!optimize 2
-- H.264 / AVC video decoder (progressive 4:2:0, 8-bit): Baseline, Main and High profiles -- CAVLC and CABAC, I / P / B
-- slices, 8x8 transforms, scaling matrices, weighted prediction, spatial and temporal direct, long-term references,
-- the deblocking filter. Interlaced (field / MBAFF) streams, 4:2:2 / 4:4:4, more than 8 bits and slice groups (FMO)
-- are refused with a message.
--
--   local dec = H264.new(avcC)               -- avcC from Mp4.parse (nalLength, sps, pps), or nil for Annex B input
--   local pic = dec:decodeSample(buf, pos, len)   -- one access unit (an MP4 sample) -> the decoded picture or nil
--   pic.Y, pic.U, pic.V (padded planes), pic.ys / pic.cs (strides), pic.yo / pic.co (offset of pixel 0,0),
--   dec.width, dec.height (cropped size), dec.cropX, dec.cropY, dec.fullRange, dec.bt709
--   The planes are valid until the next decodeSample call.

local band, bor, bxor, rshift, lshift, arshift = bit32.band, bit32.bor, bit32.bxor, bit32.rshift, bit32.lshift, bit32.arshift
local countlz, byteswap = bit32.countlz, bit32.byteswap
local readu8, writeu8, readu32 = buffer.readu8, buffer.writeu8, buffer.readu32
local abs, min, max = math.abs, math.min, math.max

local H264 = {}

local function fail(msg)
	error("H.264: " .. msg, 0)
end

local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

local CTX_I = "14f10236034a14f10236034ae47fe968fa35ff36073300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000029003f003f003ff75304560061f9480d29033e000b01370045ef7ff3660052f94aeb6be57fe17fe87fee5fe57feb72e27fef7bf473f07af573f43ffe44f154f368fd46f85df65ae27fff4afa61f95bec7ffc38fb52f94cea7df95df557fd4dfb47fc3ffc44f454f93ef941083d0538fe420140003dfe4e013207340a23002c0b26012d002e052c1f11013307321c1310210e3ef36cf164f365f35bf45ef658f054f656f953f357ed5e01460048fb4a123bf866f164005ffc4b0248f54bfd470f2ef345003e00411525f14809391036003e0c4818000f0908190d120f090d130a250c12061d14210f1e042d013a003e073d0c260b2d0f270b2a0d2c102d0c290a311e22122a0a371133112e00591aed16ef1aef1ee71cec21e925e521e928e426ef21f528f129fa260129111efa1b031a1625f023fc26f826fd250326052a00231027160e301b25153c0c440261fd47fa2afb32fd36fe3e003a013ffe48ff4af75bfb43fb1bfd27fe2c002ef040f844f64efa4df656f45cf137f63cfa3efc41f449f84cf950f758ef6ef561ec54f54ffa49fc4af356f360f561ed75f84efb21fc30fe35fd3ef347f64ff456f35af2610000fa5dfa54f84f0042ff47003efe3cfe3bfb4bfd3efc3af742ff4f004703440a2cf93e0f240e28101b0c1d012c14241220052a01300a3e112e0940f468f561f060f958f855f955f755f3580442fd4dfd4cfa4c0a3aff4cff53f963f25f025f004cfb4a0046f54b01440041f249033e043eff44f34b0b3705400c460f06061307100c0e120d0d0b0d0f0f100c170d170f140e1a0e2c1128112f1811151519161f1b161d13230e320a39073ffe4dfc52fd5e0945f46d24dd24de20e625e22ce022ee22f128f121f923fb21002602210d17230d3a1dfd1a00161e1ff923f122fd220324ff2205200b2305220c270b1e1d221a1d2713421f151f1f1932ef78ec70ee72f555f15cf259e647f151f2500044f246e838e944e832f54a17f31af328f131f22c032d062c2221361352fd4bff170122012b0036fe37003d01400044f75cf26af361f15af45aee58f649f74ff256f649f646f645fb42f740fb3a023b15f618f51cf81cff1d031d0923141d240e43ef7bf473f07af573f43ffe44f154f368fd46f85df65ae27fef7bf473f07af573f43ffe44f154f368fd46f85df65ae27ff95df557fd4dfb47fc3ffc44f454f93ef941083d0538fe420140003dfe4e013207340a23002c0b26012d002e052c1f11013307321c1310210e3ef36cf164f365f35bf45ef658f054f656f953f357ed5e01460048fb4a123bf95df557fd4dfb47fc3ffc44f454f93ef941083d0538fe420140003dfe4e013207340a23002c0b26012d002e052c1f11013307321c1310210e3ef36cf164f365f35bf45ef658f054f656f953f357ed5e01460048fb4a123b18000f0908190d120f090d130a250c12061d14210f1e042d013a003e073d0c260b2d0f270b2a0d2c102d0c290a311e22122a0a371133112e00591aed16ef1aef1ee71cec21e925e521e928e426ef21f528f129fa2601291118000f0908190d120f090d130a250c12061d14210f1e042d013a003e073d0c260b2d0f270b2a0d2c102d0c290a311e22122a0a371133112e00591aed16ef1aef1ee71cec21e925e521e928e426ef21f528f129fa26012911ef78ec70ee72f555f15cf259e647f151f2500044f246e838e944e832f54af26af361f15af45aee58f649f74ff256f649f646f645fb42f740fb3a023b17f31af328f131f22c032d062c222136135215f618f51cf81cff1d031d0923141d240e43fd4bff170122012b0036fe37003d01400044f75cef78ec70ee72f555f15cf259e647f151f2500044f246e838e944e832f54af26af361f15af45aee58f649f74ff256f649f646f645fb42f740fb3a023b17f31af328f131f22c032d062c222136135215f618f51cf81cff1d031d0923141d240e43fd4bff170122012b0036fe37003d01400044f75cfa5dfa54f84f0042ff47003efe3cfe3bfb4bfd3efc3af742ff4f004703440a2cf93e0f240e28101b0c1d012c14241220052a01300a3e112e0940f468f561f060f958f855f955f755f3580442fd4dfd4cfa4c0a3aff4cff53fa5dfa54f84f0042ff47003efe3cfe3bfb4bfd3efc3af742ff4f004703440a2cf93e0f240e28101b0c1d012c14241220052a01300a3e112e0940f468f561f060f958f855f955f755f3580442fd4dfd4cfa4c0a3aff4cff530f06061307100c0e120d0d0b0d0f0f100c170d170f140e1a0e2c1128112f1811151519161f1b161d13230e320a39073ffe4dfc52fd5e0945f46d24dd24de20e625e22ce022ee22f128f121f923fb21002602210d17230d3a0f06061307100c0e120d0d0b0d0f0f100c170d170f140e1a0e2c1128112f1811151519161f1b161d13230e320a39073ffe4dfc52fd5e0945f46d24dd24de20e625e22ce022ee22f128f121f923fb21002602210d17230d3afd47fa2afb32fd36fe3e003a013ffe48ff4af75bfb43fb1bfd27fe2c002ef040f844f64efa4df656f45cf137f63cfa3efc41f449f84cf950f758ef6efd47fa2afb32fd36fe3e003a013ffe48ff4af75bfb43fb1bfd27fe2c002ef040f844f64efa4df656f45cf137f63cfa3efc41f449f84cf950f758ef6efd46f85df65ae27ffd46f85df65ae27ffd46f85df65ae27f"
local CTX_PB = "14f10236034a14f10236034ae47fe968fa35ff36073317211702150001090031db760539f34ef541013e0c31fc4911321240092b1d001a43105a0968d27fec680143f34ef541013efa56ef5ffa3d092dfd45fa51f56006370743fb560258003afd4cf65e05360445fd510058f943fb4afc4afb50f948013a0029003f003f003ff75304560061f9480d29033e002dfc4efd60e57ee462e765e943e452ec5ef053ea6eeb5bee66f35de37ff95cfb59f960f36cfd2eff41ff39f75dfd4af75cf857e97e0536063c063b0645ff300044fc45f858fe55fa4eff4bf94d02360532fd440132062afc51013ffc4600430239fe4c0b230440013d0b2312190c180d1d0d24f65df949fe490d2e0931f964093502350535fe3d00380038f33ffb3cff3e0439fa4504390e2704330d440340013d093f07321027052c04340b30fb3cff3b003b1621052c0e2bff4e003c09450b1c0228032c0031002e022c0233002f0427023e062e00360336023a043f063306390735063406370b2d0e240835ff520737fd4e0f2e161fff5419071ef91c031c04200022ff1e061e0620091f131a1b1a1e25141c2211460143053b0943101e12201223161d181f1726122b14290b3f093b0940ff5efe59f76cfa4cfe2c002d0034fd40fe3bfc46fc4bf852ef66f74d0318002a00300037fa3bf947f453f557e277013afd1dff240126022bfa37003a0040fd4af65a0046fc1d051f072a013bfe3afd48fd51f561003a08050a0e0e120d1b0228003afd46fa4ff8550000f36af06af657eb72ee6ef262ea6eeb6aee67eb6be96ce670f660f45ffb5bf75dea5efb560943fc50f655ff46073c093a053d0c320f32123111360a29072eff33073108340929062f02370d290a2c063205350d31043f0640fe45fe3b06460a2c091f0c2b03350e220a26fd340d281120072c07260d320a391a2b0e0b0b0e090b120b150917fe20f120f122eb27e92adf29e12ee426f4151d2de835d330e641d52bed27f61e09121a141b0039f252fb4bed61dd7d1b001c001ffc1b0622081e0a1816211316201a1f15291a2c172f10410e47083c063f1141151817141a171b201c171c18172818201c1d172a13391635163d0b560c280b330e3bfc4ff947fb45f746f842f644ed49f445f046f143ec3eed46f042ea41ec3f09fe1af721f727f929fe2d0331092d1b243bfa42f923f92af82dfb30f438fa3cfb3ef842f84cfb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023b15f321f227f92efe33023c063d1137222a3ef95cfb59f960f36cfd2eff41ff39f75dfd4af75cf857e97ef95cfb59f960f36cfd2eff41ff39f75dfd4af75cf857e97efe55fa4eff4bf94d02360532fd440132062afc51013ffc4600430239fe4c0b230440013d0b2312190c180d1d0d24f65df949fe490d2e0931f964093502350535fe3d00380038f33ffb3cff3e0439fa4504390e2704330d44fe55fa4eff4bf94d02360532fd440132062afc51013ffc4600430239fe4c0b230440013d0b2312190c180d1d0d24f65df949fe490d2e0931f964093502350535fe3d00380038f33ffb3cff3e0439fa4504390e2704330d440b1c0228032c0031002e022c0233002f0427023e062e00360336023a043f063306390735063406370b2d0e240835ff520737fd4e0f2e161fff5419071ef91c031c04200022ff1e061e0620091f131a1b1a1e25141c2211460b1c0228032c0031002e022c0233002f0427023e062e00360336023a043f063306390735063406370b2d0e240835ff520737fd4e0f2e161fff5419071ef91c031c04200022ff1e061e0620091f131a1b1a1e25141c221146fc4ff947fb45f746f842f644ed49f445f046f143ec3eed46f042ea41ec3ffb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023b09fe1af721f727f929fe2d0331092d1b243b15f321f227f92efe33023c063d1137222a3efa42f923f92af82dfb30f438fa3cfb3ef842f84cfc4ff947fb45f746f842f644ed49f445f046f143ec3eed46f042ea41ec3ffb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023b09fe1af721f727f929fe2d0331092d1b243b15f321f227f92efe33023c063d1137222a3efa42f923f92af82dfb30f438fa3cfb3ef842f84cf36af06af657eb72ee6ef262ea6eeb6aee67eb6be96ce670f660f45ffb5bf75dea5efb560943fc50f655ff46073c093a053d0c320f32123111360a29072eff33073108340929062f02370d290a2c063205350d31043f0640f36af06af657eb72ee6ef262ea6eeb6aee67eb6be96ce670f660f45ffb5bf75dea5efb560943fc50f655ff46073c093a053d0c320f32123111360a29072eff33073108340929062f02370d290a2c063205350d31043f06400e0b0b0e090b120b150917fe20f120f122eb27e92adf29e12ee426f4151d2de835d330e641d52bed27f61e09121a141b0039f252fb4bed61dd7d1b001c001ffc1b0622081e0a1816211316201a1f15291a2c172f10410e470e0b0b0e090b120b150917fe20f120f122eb27e92adf29e12ee426f4151d2de835d330e641d52bed27f61e09121a141b0039f252fb4bed61dd7d1b001c001ffc1b0622081e0a1816211316201a1f15291a2c172f10410e47fa4cfe2c002d0034fd40fe3bfc46fc4bf852ef66f74d0318002a00300037fa3bf947f453f557e277013afd1dff240126022bfa37003a0040fd4af65afa4cfe2c002d0034fd40fe3bfc46fc4bf852ef66f74d0318002a00300037fa3bf947f453f557e277013afd1dff240126022bfa37003a0040fd4af65afd4af75cf857e97efd4af75cf857e97efd4af75cf857e97e14f10236034a14f10236034ae47fe968fa35ff360733161922001000fe090429e3760241fa47f34f05340932fd460a361a2213162800390229241a45d37ff165fc4cfa47f34f05340645f35a0034082bfe45fb52f660023b024bfd57fd640138fd4afa55003bfd51f956fb5fff42ff4d0146fe56fb48003d0029003f003f003ff75304560061f9480d29033e0d0f07330250d97fee5bef60e651dd62e866e961e577e863eb6eee66dc7f0050fb59f95efc5c00270041f154dd7ffe49f468f75be17f033707380737083dfd350044f94af758f367f35bf759f25cf84cf457e96ee869f64eec70ef63b27fba7fce7fd27ffc42fb4efc47f848023bff37f946fa4bf859de77fd4b20141e16d47f0036fb3d003aff3cfd3df843e754f24afb4105340239003df745f5461237fc47003a073d092912190920052b092f002c0033022e1326fc420f260c2a09220059042d0a1c0a1f21f534d5120f1c0023ea26e7220027ee20f466a2000038f121fc1d0a25fb33e327f734de45c643c12cfb200737e3200100001b2421e722e224e426e426e522ee23f022f220f825fa23001e0a1c121a191d29004b0248084d0e23121f1123151e112d142a122d1b1a1036074210380b490a43f674e970f147f93d0035fb42f54df750f754f657de7feb65fd27fb35f93df54bf14def5be76be76fe47af54cf62cf634f639f73af048f945fc45fb4af7560242f72201200b1f0534fe37fe430049f859033407040a08110810130325ff3dfb49ff46fc4e0000eb7ee97cec6ee67ee77cef69e579e575ef66e675e574df7af65ff264f85fef6fe472fa59fe50fc52f755f851ff48054001430938004501450745f945fa43f04dfe40023dfa43fd400239fd41fd42003e0933ff42fe47fe4bff46f7480e3c1025002f12230b250c290a2902300c290d29003b033213280342123213fa12fa0e001af41ff021e721ea25e427e22ae22fd62ddc31de29ef200945b93fc142c04db636d934dd29f6240028ff1e0e1c1a17250c370b4125df27dc28db26e22edf2ae228e831e326f428f626fd2efb1f141d1e192c0c300b311a2d161617161b1521141a1c1e181b22122a192712320c4615360e470b53192015311536fb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023b11f620f32af731fb35004003440a421b2f39fb470018ff24fe2afe34f739fa3ffc41fc43f952fd51fd4cf948fa4ef448f244fd46fa4cfb42fb3e0039fc3df73c0136023a11f620f32af731fb35004003440a421b2f390050fb59f95efc5c00270041f154dd7ffe49f468f75be17f0050fb59f95efc5c00270041f154dd7ffe49f468f75be17ff367f35bf759f25cf84cf457e96ee869f64eec70ef63b27fba7fce7fd27ffc42fb4efc47f848023bff37f946fa4bf859de77fd4b20141e16d47f0036fb3d003aff3cfd3df843e754f24afb4105340239003df745f5461237f367f35bf759f25cf84cf457e96ee869f64eec70ef63b27fba7fce7fd27ffc42fb4efc47f848023bff37f946fa4bf859de77fd4b20141e16d47f0036fb3d003aff3cfd3df843e754f24afb4105340239003df745f5461237042d0a1c0a1f21f534d5120f1c0023ea26e7220027ee20f466a2000038f121fc1d0a25fb33e327f734de45c643c12cfb200737e3200100001b2421e722e224e426e426e522ee23f022f220f825fa23001e0a1c121a191d29042d0a1c0a1f21f534d5120f1c0023ea26e7220027ee20f466a2000038f121fc1d0a25fb33e327f734de45c643c12cfb200737e3200100001b2421e722e224e426e426e522ee23f022f220f825fa23001e0a1c121a191d29fb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023bfd51fd4cf948fa4ef448f244fd46fa4cfb42fb3e0039fc3df73c0136023a11f620f32af731fb35004003440a421b2f3911f620f32af731fb35004003440a421b2f39fb470018ff24fe2afe34f739fa3ffc41fc43f952fb55fa51f64df951ef50ee49fc4af653f747f743ff3df842f242003b023bfd51fd4cf948fa4ef448f244fd46fa4cfb42fb3e0039fc3df73c0136023a11f620f32af731fb35004003440a421b2f3911f620f32af731fb35004003440a421b2f39fb470018ff24fe2afe34f739fa3ffc41fc43f952eb7ee97cec6ee67ee77cef69e579e575ef66e675e574df7af65ff264f85fef6fe472fa59fe50fc52f755f851ff48054001430938004501450745f945fa43f04dfe40023dfa43fd400239fd41fd42003e0933ff42fe47fe4beb7ee97cec6ee67ee77cef69e579e575ef66e675e574df7af65ff264f85fef6fe472fa59fe50fc52f755f851ff48054001430938004501450745f945fa43f04dfe40023dfa43fd400239fd41fd42003e0933ff42fe47fe4b13fa12fa0e001af41ff021e721ea25e427e22ae22fd62ddc31de29ef200945b93fc142c04db636d934dd29f6240028ff1e0e1c1a17250c370b4125df27dc28db26e22edf2ae228e831e326f428f626fd2efb1f141d1e192c13fa12fa0e001af41ff021e721ea25e427e22ae22fd62ddc31de29ef200945b93fc142c04db636d934dd29f6240028ff1e0e1c1a17250c370b4125df27dc28db26e22edf2ae228e831e326f428f626fd2efb1f141d1e192ce970f147f93d0035fb42f54df750f754f657de7feb65fd27fb35f93df54bf14def5be76be76fe47af54cf62cf634f639f73af048f945fc45fb4af756e970f147f93d0035fb42f54df750f754f657de7feb65fd27fb35f93df54bf14def5be76be76fe47af54cf62cf634f639f73af048f945fc45fb4af756fe49f468f75be17ffe49f468f75be17ffe49f468f75be17f14f10236034a14f10236034ae47fe968fa35ff3607331d1019000e00f633fd3ee5631a10fc55e86605390639ef490e391428140a1d003600252a0c61e07fea75fe4afc55e8660539fa5df258fa2c0437f559f167eb741339143a04540660013ffb55f36a053f064bfd5aff650337fc4ffe4bf461f932013c0029003f003f003ff75304560061f9480d29033e0722f758ec7fdc7fef5bf25fe754e756f459ef5be17ff24cee67f35adb7f0b50054c0254054efa37043df253db7ffb4ff568f55be27f0041fe4f0048fc5cfa380344f847f362fc56f458fb52fd48fc43f848f059f745ff3b05420439fc47fe47023aff4afc2cff45003ef933fc2ffa2afd29fa35084cf74ef55309340043fb5a0143f148fb4bf850eb53eb40f31fe740e35e094b113ff84afb23fe1b0d5b0341f945084df642033efd44ec51001e0107fd17eb4a1042e97c11252cee32deea7f0427002a07220b1d081f0625072a032808210d2b0d24042f0337023a063c082c0b2c0e2a0730043804340d250931133a0a300c2d00451421083f23ee21e71cfd180a1b0022f234d427e813111f19241d1821220f1e1416491422131f1b2c13100f240f24151c19151e141f0c1b10182a005d0e380f391a26e87fe873ea52f73e0035003bf255f359f35ef55ce37feb64f239f443f547f64deb55f058e968f162db7ff652f830f83df842f946f24bf64ff753f45cee6cfc4fea45f04bfe3a013af34ef753fc51f363f351fa26f33efa3afe3bf049f64cf356f753f6570000ea7fe77fe778e57fed72e975e776e675e871e476e178db7cf65ef166f663f36ace7ffb5c1139fb56f35ef45bfe4d0047ff490440f95105400f3901430044f6430144004d02400044fb4e0737053b02410e360f2c053c0246fe4cee560c460540f4460b37053800450241fa4a05360736fa4cf552fe4dfe4d192a11f310f711f41beb25e229d82ad730d127e02ed834cd2ed734d92bed200b3dc938d23ece51bd2dec23fe1c0f220127011e111426122d0f36004f24f025f225ef2001220f1d0f181922161f1023121f1c2129241c1b2f153e121f131a241818171b10181e1f1d1629162a103c0f340e3c034ef07b15351638193d15211332113dfd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f54409fe1ef61ffc21ff21071f0c25171f261440f747f925f82cf531f638f43bf83ff743fa44f64ffd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f54409fe1ef61ffc21ff21071f0c25171f2614400b50054c0254054efa37043df253db7ffb4ff568f55be27f0b50054c0254054efa37043df253db7ffb4ff568f55be27ffc56f458fb52fd48fc43f848f059f745ff3b05420439fc47fe47023aff4afc2cff45003ef933fc2ffa2afd29fa35084cf74ef55309340043fb5a0143f148fb4bf850eb53eb40f31fe740e35e094b113ff84afb23fe1b0d5bfc56f458fb52fd48fc43f848f059f745ff3b05420439fc47fe47023aff4afc2cff45003ef933fc2ffa2afd29fa35084cf74ef55309340043fb5a0143f148fb4bf850eb53eb40f31fe740e35e094b113ff84afb23fe1b0d5b0427002a07220b1d081f0625072a032808210d2b0d24042f0337023a063c082c0b2c0e2a0730043804340d250931133a0a300c2d00451421083f23ee21e71cfd180a1b0022f234d427e813111f19241d1821220f1e1416490427002a07220b1d081f0625072a032808210d2b0d24042f0337023a063c082c0b2c0e2a0730043804340d250931133a0a300c2d00451421083f23ee21e71cfd180a1b0022f234d427e813111f19241d1821220f1e141649fd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f544fd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f54409fe1ef61ffc21ff21071f0c25171f26144009fe1ef61ffc21ff21071f0c25171f261440f747f925f82cf531f638f43bf83ff743fa44f64ffd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f544fd4ef84af748f648ee4bf447f53ffb46ef4bf248f043f835f23bf734f54409fe1ef61ffc21ff21071f0c25171f26144009fe1ef61ffc21ff21071f0c25171f261440f747f925f82cf531f638f43bf83ff743fa44f64fea7fe77fe778e57fed72e975e776e675e871e476e178db7cf65ef166f663f36ace7ffb5c1139fb56f35ef45bfe4d0047ff490440f95105400f3901430044f6430144004d02400044fb4e0737053b02410e360f2c053c0246ea7fe77fe778e57fed72e975e776e675e871e476e178db7cf65ef166f663f36ace7ffb5c1139fb56f35ef45bfe4d0047ff490440f95105400f3901430044f6430144004d02400044fb4e0737053b02410e360f2c053c024611f310f711f41beb25e229d82ad730d127e02ed834cd2ed734d92bed200b3dc938d23ece51bd2dec23fe1c0f220127011e111426122d0f36004f24f025f225ef2001220f1d0f181922161f1023121f1c2129241c1b2f153e11f310f711f41beb25e229d82ad730d127e02ed834cd2ed734d92bed200b3dc938d23ece51bd2dec23fe1c0f220127011e111426122d0f36004f24f025f225ef2001220f1d0f181922161f1023121f1c2129241c1b2f153ee873ea52f73e0035003bf255f359f35ef55ce37feb64f239f443f547f64deb55f058e968f162db7ff652f830f83df842f946f24bf64ff753f45cee6ce873ea52f73e0035003bf255f359f35ef55ce37feb64f239f443f547f64deb55f058e968f162db7ff652f830f83df842f946f24bf64ff753f45cee6cfb4ff568f55be27ffb4ff568f55be27ffb4ff568f55be27f"
local LPS_TAB = { 128, 128, 128, 123, 116, 111, 105, 100, 95, 90, 85, 81, 77, 73, 69, 66, 62, 59, 56, 53, 51, 48, 46, 43, 41, 39, 37, 35, 33, 32, 30, 29, 27, 26, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 2, 176, 167, 158, 150, 142, 135, 128, 122, 116, 110, 104, 99, 94, 89, 85, 80, 76, 72, 69, 65, 62, 59, 56, 53, 50, 48, 45, 43, 41, 39, 37, 35, 33, 31, 30, 28, 27, 26, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 9, 9, 9, 8, 8, 7, 7, 2, 208, 197, 187, 178, 169, 160, 152, 144, 137, 130, 123, 117, 111, 105, 100, 95, 90, 86, 81, 77, 73, 69, 66, 63, 59, 56, 54, 51, 48, 46, 43, 41, 39, 37, 35, 33, 32, 30, 29, 27, 26, 25, 23, 22, 21, 20, 19, 18, 17, 16, 15, 15, 14, 13, 12, 12, 11, 11, 10, 10, 9, 9, 8, 2, 240, 227, 216, 205, 195, 185, 175, 166, 158, 150, 142, 135, 128, 122, 116, 110, 104, 99, 94, 89, 85, 80, 76, 72, 69, 65, 62, 59, 56, 53, 50, 48, 45, 43, 41, 39, 37, 35, 33, 31, 30, 28, 27, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 14, 13, 12, 12, 11, 11, 10, 9, 2 }
local TRANS_LPS = { 0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12, 13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24, 24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33, 33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63 }
local LAST8 = { 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8 }
local SIG8 = { 0, 1, 2, 3, 4, 5, 5, 4, 4, 3, 3, 4, 4, 4, 5, 5, 4, 4, 4, 4, 3, 3, 6, 7, 7, 7, 8, 9, 10, 9, 8, 7, 7, 6, 11, 12, 13, 11, 6, 7, 8, 9, 14, 10, 9, 8, 6, 11, 12, 13, 11, 6, 9, 14, 10, 9, 11, 12, 13, 11, 14, 10, 12 }
local CT_LEN = { 1, 0, 0, 0, 6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6, 11, 10, 9, 7, 13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10, 14, 14, 13, 11, 14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14, 16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16, 16, 16, 16, 16, 2, 0, 0, 0, 6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4, 8, 7, 7, 5, 9, 8, 8, 6, 11, 9, 9, 6, 11, 11, 11, 7, 12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12, 13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14, 4, 0, 0, 0, 6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4, 7, 5, 5, 4, 7, 6, 6, 4, 7, 6, 6, 4, 8, 7, 7, 5, 8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8, 10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 6, 0, 0, 0, 6, 6, 0, 0, 6, 6, 6, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6 }
local CT_BITS = { 1, 0, 0, 0, 5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3, 7, 6, 5, 4, 15, 6, 5, 4, 11, 14, 5, 4, 8, 10, 13, 4, 15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8, 15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8, 3, 0, 0, 0, 11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4, 4, 6, 5, 6, 7, 6, 5, 8, 15, 6, 5, 4, 11, 14, 13, 4, 15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8, 15, 14, 13, 12, 11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4, 15, 0, 0, 0, 15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11, 11, 8, 9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13, 11, 14, 10, 12, 15, 10, 13, 12, 11, 14, 9, 12, 8, 10, 13, 8, 13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4, 3, 2, 3, 0, 0, 0, 0, 1, 0, 0, 4, 5, 6, 0, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63 }
local CDC_LEN = { 2, 0, 0, 0, 6, 1, 0, 0, 6, 6, 3, 0, 6, 7, 7, 6, 6, 8, 8, 7 }
local CDC_BITS = { 1, 0, 0, 0, 7, 1, 0, 0, 4, 6, 1, 0, 3, 3, 2, 5, 2, 3, 2, 0 }
local TZ_LEN = { 1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9, 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 0, 4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6, 0, 0, 5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5, 0, 0, 0, 4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5, 0, 0, 0, 0, 6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6, 0, 0, 0, 0, 0, 6, 5, 3, 3, 3, 2, 3, 4, 3, 6, 0, 0, 0, 0, 0, 0, 6, 4, 5, 3, 2, 2, 3, 3, 6, 0, 0, 0, 0, 0, 0, 0, 6, 6, 4, 2, 2, 3, 2, 5, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 3, 2, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 3, 3, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 2, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local TZ_BITS = { 1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1, 7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0, 0, 5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0, 0, 0, 3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0, 0, 0, 0, 5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0, 0, 1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 5, 4, 3, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 3, 3, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 3, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local CTZ_LEN = { 1, 2, 3, 3, 1, 2, 2, 0, 1, 1, 0, 0 }
local CTZ_BITS = { 1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0 }
local RUN_LEN = { 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0 }
local RUN_BITS = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 3, 2, 5, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 }
local ALPHA = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28, 32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182, 203, 226, 255, 255 }
local BETA = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18 }
local TC0 = { -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 0, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 0, 1, -1, 0, 1, 1, -1, 0, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 1, -1, 1, 1, 2, -1, 1, 1, 2, -1, 1, 1, 2, -1, 1, 1, 2, -1, 1, 2, 3, -1, 1, 2, 3, -1, 2, 2, 3, -1, 2, 2, 4, -1, 2, 3, 4, -1, 2, 3, 4, -1, 3, 3, 5, -1, 3, 4, 6, -1, 3, 4, 6, -1, 4, 5, 7, -1, 4, 5, 8, -1, 4, 6, 9, -1, 5, 7, 10, -1, 6, 8, 11, -1, 6, 8, 13, -1, 7, 10, 14, -1, 8, 11, 16, -1, 9, 12, 18, -1, 10, 13, 20, -1, 11, 15, 23, -1, 13, 17, 25 }
local DEF4 = { 6, 13, 20, 28, 13, 20, 28, 32, 20, 28, 32, 37, 28, 32, 37, 42, 10, 14, 20, 24, 14, 20, 24, 27, 20, 24, 27, 30, 24, 27, 30, 34 }
local DEF8 = { 6, 10, 13, 16, 18, 23, 25, 27, 10, 11, 16, 18, 23, 25, 27, 29, 13, 16, 18, 23, 25, 27, 29, 31, 16, 18, 23, 25, 27, 29, 31, 33, 18, 23, 25, 27, 29, 31, 33, 36, 23, 25, 27, 29, 31, 33, 36, 38, 25, 27, 29, 31, 33, 36, 38, 40, 27, 29, 31, 33, 36, 38, 40, 42, 9, 13, 15, 17, 19, 21, 22, 24, 13, 13, 17, 19, 21, 22, 24, 25, 15, 17, 19, 21, 22, 24, 25, 27, 17, 19, 21, 22, 24, 25, 27, 28, 19, 21, 22, 24, 25, 27, 28, 30, 21, 22, 24, 25, 27, 28, 30, 32, 22, 24, 25, 27, 28, 30, 32, 33, 24, 25, 27, 28, 30, 32, 33, 35 }
local CHROMA_QP = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39 }
local CBP_INTRA = { 47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46, 16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4, 8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41 }
local CBP_INTER = { 0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13, 14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46, 17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41 }
local DQ4 = { 10, 13, 16, 11, 14, 18, 13, 16, 20, 14, 18, 23, 16, 20, 25, 18, 23, 29 }
local DQ8 = { 20, 18, 32, 19, 25, 24, 22, 19, 35, 21, 28, 26, 26, 23, 42, 24, 33, 31, 28, 25, 45, 26, 35, 33, 32, 28, 51, 30, 40, 38, 36, 32, 58, 34, 46, 43 }


local function hexBytes(hex, signed)
	local t = table.create(#hex // 2)
	for i = 1, #hex // 2 do
		local v = tonumber(string.sub(hex, i * 2 - 1, i * 2), 16)
		if signed and v >= 128 then
			v -= 256
		end
		t[i] = v
	end
	return t
end
local CTXI = hexBytes(CTX_I, true)
local CTXPB = hexBytes(CTX_PB, true)

-- zigzag scans (raster position of the n-th coefficient)
local ZZ4 = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 }
local ZZ8 = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55,
	62, 63,
}
-- luma4x4BlkIdx -> x, y (in 4x4 blocks) inside the macroblock, and back
local BLK_X = { 0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3 }
local BLK_Y = { 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3 }
local BLK_AT = {} -- [x + 4y] -> blkIdx
for i = 1, 16 do
	BLK_AT[BLK_X[i] + 4 * BLK_Y[i]] = i - 1
end

------------------------------------------------------------------------------------------------------------------------
-- bit reader over an RBSP buffer (emulation prevention removed, padded with zero bytes)

local RB = buffer.create(16)
local BP = 0 -- bit position
local RBLEN = 0 -- bytes of payload
local RBSTOP = 0 -- bit position of the rbsp_stop_one_bit

local function u(n)
	if n == 0 then
		return 0
	end
	local w = lshift(byteswap(readu32(RB, rshift(BP, 3))), band(BP, 7))
	BP += n
	return rshift(w, 32 - n)
end
local function u1()
	local v = band(rshift(readu8(RB, rshift(BP, 3)), 7 - band(BP, 7)), 1)
	BP += 1
	return v
end
local function ue()
	local w = lshift(byteswap(readu32(RB, rshift(BP, 3))), band(BP, 7))
	local lz = countlz(w)
	if lz > 24 then
		lz = 0
		while u1() == 0 do
			lz += 1
			if lz > 31 then
				fail("broken data (a run of zero bits)")
			end
		end
		if lz > 16 then
			return lshift(1, lz) - 1 + u(lz - 16) * 65536 + u(16)
		end
		return lshift(1, lz) - 1 + u(lz)
	end
	BP += lz
	return u(lz + 1) - 1
end
local function se()
	local k = ue()
	if band(k, 1) == 1 then
		return (k + 1) // 2
	end
	return -(k // 2)
end
local function moreRbspData()
	return BP < RBSTOP
end

-- NAL payload [pos, pos + len) -> RB without emulation prevention bytes
local function loadRbsp(src, pos, len)
	if buffer.len(RB) < len + 16 then
		RB = buffer.create(len + 64)
	else
		buffer.fill(RB, len, 0, 16)
	end
	local o = 0
	local zeros = 0
	local stop = pos + len
	local i = pos
	while i < stop do
		local c = readu8(src, i)
		if zeros >= 2 and c == 3 then
			zeros = 0
		else
			writeu8(RB, o, c)
			o += 1
			if c == 0 then
				zeros += 1
			else
				zeros = 0
			end
		end
		i += 1
	end
	buffer.fill(RB, o, 0, 16)
	RBLEN = o
	-- the stop bit: the last 1 bit
	local last = o - 1
	while last >= 0 and readu8(RB, last) == 0 do
		last -= 1
	end
	if last < 0 then
		RBSTOP = 0
	else
		local c = readu8(RB, last)
		local tz = 0
		while band(c, 1) == 0 do
			c = rshift(c, 1)
			tz += 1
		end
		RBSTOP = last * 8 + 7 - tz
	end
	BP = 0
end

-- VLC tables (MSB-first codes up to 16 bits): two-level lookup of 8 + 8 bits; entry = symbol * 32 + length
local function buildVlc(lens, codes, n)
	local t1 = table.create(256, false)
	local subs = {}
	for s = 0, n - 1 do
		local l = lens[s + 1]
		if l > 0 then
			local c = codes[s + 1]
			if l <= 8 then
				local base = lshift(c, 8 - l)
				for k = 0, lshift(1, 8 - l) - 1 do
					t1[base + k + 1] = s * 32 + l
				end
			else
				local pre = rshift(c, l - 8)
				local sub = subs[pre]
				if not sub then
					sub = table.create(256, false)
					subs[pre] = sub
					t1[pre + 1] = sub
				end
				local base = lshift(band(c, lshift(1, l - 8) - 1), 16 - l)
				for k = 0, lshift(1, 16 - l) - 1 do
					sub[base + k + 1] = s * 32 + l
				end
			end
		end
	end
	return t1
end
local function readVlc(t1)
	local w = rshift(lshift(byteswap(readu32(RB, rshift(BP, 3))), band(BP, 7)), 16)
	local e = t1[rshift(w, 8) + 1]
	if type(e) == "table" then
		e = e[band(w, 255) + 1]
	end
	if not e then
		fail("broken data (an unknown code)")
	end
	BP += band(e, 31)
	return rshift(e, 5)
end

local function slice(t, from, n)
	local out = table.create(n)
	for i = 1, n do
		out[i] = t[from + i]
	end
	return out
end
local COEFF_TOKEN = {}
for k = 0, 3 do
	COEFF_TOKEN[k] = buildVlc(slice(CT_LEN, k * 68, 68), slice(CT_BITS, k * 68, 68), 68)
end
local CHROMA_DC_TOKEN = buildVlc(CDC_LEN, CDC_BITS, 20)
local TOTAL_ZEROS = {}
for k = 1, 15 do
	TOTAL_ZEROS[k] = buildVlc(slice(TZ_LEN, (k - 1) * 16, 16), slice(TZ_BITS, (k - 1) * 16, 16), 16)
end
local CHROMA_DC_TZ = {}
for k = 1, 3 do
	CHROMA_DC_TZ[k] = buildVlc(slice(CTZ_LEN, (k - 1) * 4, 4), slice(CTZ_BITS, (k - 1) * 4, 4), 4)
end
local RUN_BEFORE = {}
for k = 1, 7 do
	RUN_BEFORE[k] = buildVlc(slice(RUN_LEN, (k - 1) * 16, 16), slice(RUN_BITS, (k - 1) * 16, 16), 16)
end

------------------------------------------------------------------------------------------------------------------------
-- CABAC arithmetic decoder (offset kept with `CB` extra low bits, like a window into the stream)

local CR, CV, CB, CP = 510, 0, 0, 0 -- range, value, extra bits, next byte
local CTX = table.create(1024, 0) -- state * 2 + mps
local NORM9 = table.create(512, 0)
for r = 1, 511 do
	local s = 0
	while lshift(r, s) < 256 do
		s += 1
	end
	NORM9[r] = s
end
local LPS = LPS_TAB -- [q * 64 + state + 1]

local function cabacStart(bytePos)
	CP = bytePos
	CV = readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
	CP += 3
	CB = 15
	CR = 510
end
local function decodeBin(ctx)
	local p = CTX[ctx + 1]
	local st = rshift(p, 1)
	local rl = LPS[(rshift(CR, 6) - 4) * 64 + st + 1]
	CR -= rl
	local big = lshift(CR, CB)
	local bin
	if CV >= big then
		CV -= big
		CR = rl
		bin = 1 - band(p, 1)
		if st == 0 then
			p = TRANS_LPS[1] * 2 + bin
		else
			p = TRANS_LPS[st + 1] * 2 + band(p, 1)
		end
	else
		bin = band(p, 1)
		if st < 62 then
			p += 2
		end
	end
	CTX[ctx + 1] = p
	if CR < 256 then
		local sh = NORM9[CR]
		CR = lshift(CR, sh)
		CB -= sh
		if CB < 0 then
			CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
			CP += 3
			CB += 24
		end
	end
	return bin
end
local function decodeBypass()
	CB -= 1
	if CB < 0 then
		CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
		CP += 3
		CB += 24
	end
	local big = lshift(CR, CB)
	if CV >= big then
		CV -= big
		return 1
	end
	return 0
end
local function decodeTerminate()
	CR -= 2
	local big = lshift(CR, CB)
	if CV >= big then
		return 1
	end
	if CR < 256 then
		local sh = NORM9[CR]
		CR = lshift(CR, sh)
		CB -= sh
		if CB < 0 then
			CV = CV * 16777216 + readu8(RB, CP) * 65536 + readu8(RB, CP + 1) * 256 + readu8(RB, CP + 2)
			CP += 3
			CB += 24
		end
	end
	return 0
end
-- bit position of the arithmetic decoder in the stream (for I_PCM)
local function cabacBitPos()
	return CP * 8 - CB
end
local function cabacInitContexts(sliceQp, initIdc, isI)
	local qp = sliceQp < 0 and 0 or (sliceQp > 51 and 51 or sliceQp)
	local tab = isI and CTXI or CTXPB
	local base = isI and 0 or initIdc * 2048
	for i = 0, 1023 do
		local m, n = tab[base + i * 2 + 1], tab[base + i * 2 + 2]
		local pre = (m * qp) // 16 + n
		pre = pre < 1 and 1 or (pre > 126 and 126 or pre)
		if pre <= 63 then
			CTX[i + 1] = (63 - pre) * 2
		else
			CTX[i + 1] = (pre - 64) * 2 + 1
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- parameter sets

local HIGH_PROFILES = { [100] = true, [110] = true, [122] = true, [244] = true, [44] = true, [83] = true, [86] = true,
	[118] = true, [128] = true, [138] = true, [139] = true, [134] = true, [135] = true }

-- a scaling list (raster order) from the stream; returns list, useDefault
local function readScalingList(size)
	local scan = size == 16 and ZZ4 or ZZ8
	local list = table.create(size, 16)
	local last, nextv = 8, 8
	local useDefault = false
	for j = 0, size - 1 do
		if nextv ~= 0 then
			local delta = se()
			nextv = (last + delta + 256) % 256
			useDefault = j == 0 and nextv == 0
		end
		local v = nextv == 0 and last or nextv
		list[scan[j + 1] + 1] = v
		last = v
	end
	return list, useDefault
end
local function defaultList(i)
	if i < 3 then
		return slice(DEF4, 0, 16)
	elseif i < 6 then
		return slice(DEF4, 16, 16)
	elseif i == 6 then
		return slice(DEF8, 0, 64)
	end
	return slice(DEF8, 64, 64)
end
local function flatList(n)
	return table.create(n, 16)
end
-- lists 0..7 (6 4x4 + 2 8x8) with a fallback for missing ones
local function readScalingLists(count, fallback)
	local lists = {}
	for i = 0, count - 1 do
		local present = u1() == 1
		if present then
			local l, useDefault = readScalingList(i < 6 and 16 or 64)
			lists[i] = useDefault and defaultList(i) or l
		else
			if i == 0 or i == 3 or i == 6 or i == 7 then
				lists[i] = fallback(i)
			else
				lists[i] = lists[i - 1]
			end
		end
	end
	for i = count, 7 do
		lists[i] = fallback(i)
	end
	return lists
end

local function parseSps()
	local s = {}
	s.profile = u(8)
	u(8)
	s.level = u(8)
	s.id = ue()
	s.chromaFormat = 1
	s.bitDepth = 8
	if HIGH_PROFILES[s.profile] then
		s.chromaFormat = ue()
		if s.chromaFormat == 3 then
			u1()
		end
		local bdl = ue() + 8
		local bdc = ue() + 8
		if bdl ~= 8 or bdc ~= 8 then
			fail(("%d-bit video isn't supported (only 8-bit)"):format(math.max(bdl, bdc)))
		end
		if u1() == 1 then
			fail("lossless (transform bypass) video isn't supported")
		end
		if u1() == 1 then
			s.scaling = readScalingLists(s.chromaFormat == 3 and 12 or 8, defaultList)
		end
	end
	if s.chromaFormat ~= 1 then
		fail(s.chromaFormat == 0 and "black-and-white (4:0:0) video isn't supported" or "only 4:2:0 colour video is supported (this is 4:2:2 or 4:4:4)")
	end
	s.log2MaxFrameNum = ue() + 4
	s.pocType = ue()
	if s.pocType == 0 then
		s.log2MaxPocLsb = ue() + 4
	elseif s.pocType == 1 then
		s.deltaPicOrderAlwaysZero = u1() == 1
		s.offsetForNonRefPic = se()
		s.offsetForTopToBottom = se()
		local n = ue()
		s.refFrameOffsets = {}
		local expected = 0
		for i = 1, n do
			s.refFrameOffsets[i] = se()
			expected += s.refFrameOffsets[i]
		end
		s.expectedDeltaPerCycle = expected
	end
	s.maxRefFrames = ue()
	s.gapsAllowed = u1() == 1
	s.mbw = ue() + 1
	s.mbh = ue() + 1
	s.frameMbsOnly = u1() == 1
	if not s.frameMbsOnly then
		fail("interlaced video isn't supported (save it as progressive)")
	end
	s.direct8x8 = u1() == 1
	s.cropLeft, s.cropRight, s.cropTop, s.cropBottom = 0, 0, 0, 0
	if u1() == 1 then
		s.cropLeft, s.cropRight, s.cropTop, s.cropBottom = ue() * 2, ue() * 2, ue() * 2, ue() * 2
	end
	s.bt709 = s.mbh * 16 > 576
	s.fullRange = false
	if u1() == 1 then -- VUI: only the colour description matters here
		if u1() == 1 then
			local idc = u(8)
			if idc == 255 then
				u(16)
				u(16)
			end
		end
		if u1() == 1 then
			u1()
		end
		if u1() == 1 then
			u(3)
			s.fullRange = u1() == 1
			if u1() == 1 then
				u(8)
				u(8)
				local mc = u(8)
				if mc == 1 then
					s.bt709 = true
				elseif mc == 5 or mc == 6 then
					s.bt709 = false
				end
			end
		end
	end
	return s
end

local function parsePps(spsList)
	local p = {}
	p.id = ue()
	p.spsId = ue()
	local sps = spsList[p.spsId]
	if not sps then
		fail("a picture parameter set refers to a missing sequence parameter set")
	end
	p.cabac = u1() == 1
	p.bottomFieldPicOrder = u1() == 1
	if ue() > 0 then
		fail("slice groups (FMO) aren't supported")
	end
	p.numRefIdxL0 = ue() + 1
	p.numRefIdxL1 = ue() + 1
	p.weightedPred = u1() == 1
	p.weightedBipred = u(2)
	p.initQp = 26 + se()
	se()
	p.chromaQpOffset = se()
	p.deblockControl = u1() == 1
	p.constrainedIntra = u1() == 1
	p.redundantPicCnt = u1() == 1
	p.transform8x8 = false
	p.chromaQpOffset2 = p.chromaQpOffset
	if moreRbspData() then
		p.transform8x8 = u1() == 1
		if u1() == 1 then
			local seq = sps.scaling
			-- missing lists: the sequence's (fall-back rule B) or, when the sequence has none, the defaults (rule A)
			p.scaling = readScalingLists(6 + (p.transform8x8 and 2 or 0), function(i)
				if seq then
					return seq[i]
				end
				return defaultList(i)
			end)
		end
		p.chromaQpOffset2 = se()
	end
	-- level scales (raster order): [list][qp % 6] for 4x4 lists 0..5 and 8x8 lists 6, 7
	local lists = p.scaling or sps.scaling
	p.ls4 = {}
	p.ls8 = {}
	for li = 0, 5 do
		local w = lists and lists[li] or flatList(16)
		local per = {}
		for m = 0, 5 do
			local t = table.create(16, 0)
			for pos = 0, 15 do
				local i, j = pos % 4, pos // 4
				local v
				if i % 2 == 0 and j % 2 == 0 then
					v = DQ4[m * 3 + 1]
				elseif i % 2 == 1 and j % 2 == 1 then
					v = DQ4[m * 3 + 3]
				else
					v = DQ4[m * 3 + 2]
				end
				t[pos + 1] = w[pos + 1] * v
			end
			per[m] = t
		end
		p.ls4[li] = per
	end
	for li = 6, 7 do
		local w = lists and lists[li] or flatList(64)
		local per = {}
		for m = 0, 5 do
			local t = table.create(64, 0)
			for pos = 0, 63 do
				local i, j = pos % 8, pos // 8
				local k
				if i % 4 == 0 and j % 4 == 0 then
					k = 0
				elseif i % 2 == 1 and j % 2 == 1 then
					k = 1
				elseif i % 4 == 2 and j % 4 == 2 then
					k = 2
				elseif (i % 4 == 0 and j % 2 == 1) or (i % 2 == 1 and j % 4 == 0) then
					k = 3
				elseif (i % 4 == 0 and j % 4 == 2) or (i % 4 == 2 and j % 4 == 0) then
					k = 4
				else
					k = 5
				end
				t[pos + 1] = w[pos + 1] * DQ8[m * 6 + k + 1]
			end
			per[m] = t
		end
		p.ls8[li] = per
	end
	return p
end

------------------------------------------------------------------------------------------------------------------------
-- pictures

local PADY, PADC = 32, 16

-- macroblock kinds
local K_I4, K_I8, K_I16, K_PCM, K_P, K_PSKIP, K_B, K_BSKIP, K_BDIRECT = 1, 2, 3, 4, 5, 6, 7, 8, 9

local Decoder = {}
Decoder.__index = Decoder

local picCounter = 0
local function newPicture(D)
	local p = table.remove(D.free)
	if p then
		return p
	end
	picCounter += 1
	local W, Hh = D.mbw * 16, D.mbh * 16
	local ys, cs = W + 2 * PADY, W // 2 + 2 * PADC
	local n4 = D.mbw * 4 * D.mbh * 4
	p = {
		uid = picCounter,
		Y = buffer.create(ys * (Hh + 2 * PADY)),
		U = buffer.create(cs * (Hh // 2 + 2 * PADC)),
		V = buffer.create(cs * (Hh // 2 + 2 * PADC)),
		ys = ys,
		cs = cs,
		yo = PADY * ys + PADY,
		co = PADC * cs + PADC,
		mv0x = table.create(n4, 0),
		mv0y = table.create(n4, 0),
		mv1x = table.create(n4, 0),
		mv1y = table.create(n4, 0),
		ref0 = table.create(n4, -1),
		ref1 = table.create(n4, -1),
		rp0 = table.create(n4, 0), -- id of the picture each block refers to (for the next pictures' direct modes)
		rp1 = table.create(n4, 0),
		intra = table.create(D.mbw * D.mbh, false),
	}
	return p
end

-- extend the picture's edges into the padding (for motion vectors that point outside)
local function padPicture(D, p)
	local W, Hh = D.mbw * 16, D.mbh * 16
	local function padPlane(P, stride, org, w, h, pad)
		for y = 0, h - 1 do
			local row = org + y * stride
			buffer.fill(P, row - pad, readu8(P, row), pad)
			buffer.fill(P, row + w, readu8(P, row + w - 1), pad)
		end
		local top = org - pad
		for y = 1, pad do
			buffer.copy(P, top - y * stride, P, top, w + 2 * pad)
		end
		local bottom = org + (h - 1) * stride - pad
		for y = 1, pad do
			buffer.copy(P, bottom + y * stride, P, bottom, w + 2 * pad)
		end
	end
	padPlane(p.Y, p.ys, p.yo, W, Hh, PADY)
	padPlane(p.U, p.cs, p.co, W // 2, Hh // 2, PADC)
	padPlane(p.V, p.cs, p.co, W // 2, Hh // 2, PADC)
end

function H264.new(avcC)
	local D = setmetatable({}, Decoder)
	D.spsList, D.ppsList = {}, {}
	D.dpb = {} -- reference pictures
	D.free = {}
	D.nalLength = avcC and avcC.nalLength or 4
	D.prevPocMsb, D.prevPocLsb, D.prevFrameNumOffset, D.prevFrameNum = 0, 0, 0, 0
	D.prevRefMmco5 = false
	if avcC then
		for _, s in ipairs(avcC.sps) do
			D:nal(s, 0, buffer.len(s))
		end
		for _, s in ipairs(avcC.pps) do
			D:nal(s, 0, buffer.len(s))
		end
	end
	return D
end

-- per-picture working arrays (sized by the stream)
local function setupSize(D, sps)
	if D.mbw == sps.mbw and D.mbh == sps.mbh then
		return
	end
	D.mbw, D.mbh = sps.mbw, sps.mbh
	D.free = {}
	D.dpb = {}
	local nmb = sps.mbw * sps.mbh
	local n4 = nmb * 16
	local nc = nmb * 4
	D.mbSlice = table.create(nmb, -1)
	D.mbKind = table.create(nmb, 0)
	D.mbQp = table.create(nmb, 0)
	D.mbT8 = table.create(nmb, false)
	D.mbCbp = table.create(nmb, 0)
	D.mbChroma = table.create(nmb, 0)
	D.mbDcCbf = table.create(nmb, 0)
	D.dbIdc = table.create(nmb, 0)
	D.dbA = table.create(nmb, 0)
	D.dbB = table.create(nmb, 0)
	D.dbQpOff = table.create(nmb, 0)
	D.dbQpOff2 = table.create(nmb, 0)
	D.nnz = table.create(n4, 0)
	D.coef = table.create(n4, false)
	D.imode = table.create(n4, 2)
	D.mvd0x = table.create(n4, 0)
	D.mvd0y = table.create(n4, 0)
	D.mvd1x = table.create(n4, 0)
	D.mvd1y = table.create(n4, 0)
	D.nnzU = table.create(nc, 0)
	D.nnzV = table.create(nc, 0)
	D.W4 = sps.mbw * 4
	D.W2 = sps.mbw * 2
end

------------------------------------------------------------------------------------------------------------------------
-- slice header, picture order count, reference lists and marking

local function parseSliceHeader(D, nalType, nalRefIdc)
	local h = {}
	h.firstMb = ue()
	local st = ue()
	h.type = st % 5 -- 0 P, 1 B, 2 I, 3 SP, 4 SI
	if h.type == 3 or h.type == 4 then
		fail("SP / SI slices aren't supported")
	end
	h.ppsId = ue()
	local pps = D.ppsList[h.ppsId]
	if not pps then
		fail("a slice refers to a missing picture parameter set")
	end
	local sps = D.spsList[pps.spsId]
	h.pps, h.sps = pps, sps
	h.idr = nalType == 5
	h.refIdc = nalRefIdc
	h.frameNum = u(sps.log2MaxFrameNum)
	if h.idr then
		h.idrPicId = ue()
	end
	h.pocLsb, h.deltaPocBottom, h.deltaPoc0, h.deltaPoc1 = 0, 0, 0, 0
	if sps.pocType == 0 then
		h.pocLsb = u(sps.log2MaxPocLsb)
		if pps.bottomFieldPicOrder then
			h.deltaPocBottom = se()
		end
	elseif sps.pocType == 1 and not sps.deltaPicOrderAlwaysZero then
		h.deltaPoc0 = se()
		if pps.bottomFieldPicOrder then
			h.deltaPoc1 = se()
		end
	end
	if pps.redundantPicCnt then
		h.redundantPicCnt = ue()
	end
	if h.type == 1 then
		h.directSpatial = u1() == 1
	end
	h.numRef0, h.numRef1 = pps.numRefIdxL0, pps.numRefIdxL1
	if h.type == 0 or h.type == 1 then
		if u1() == 1 then
			h.numRef0 = ue() + 1
			if h.type == 1 then
				h.numRef1 = ue() + 1
			end
		end
	end
	if h.numRef0 > 32 or h.numRef1 > 32 then
		fail("broken data (too many reference pictures)")
	end
	-- reference list modifications
	h.mod0, h.mod1 = nil, nil
	if h.type ~= 2 then
		for list = 0, h.type == 1 and 1 or 0 do
			if u1() == 1 then
				local mods = {}
				while true do
					local idc = ue()
					if idc == 3 then
						break
					end
					if idc > 5 then
						fail("broken data (bad reference list change)")
					end
					table.insert(mods, { idc, ue() })
				end
				if list == 0 then
					h.mod0 = mods
				else
					h.mod1 = mods
				end
			end
		end
	end
	-- weights
	if (pps.weightedPred and h.type == 0) or (pps.weightedBipred == 1 and h.type == 1) then
		h.lumaLog2 = ue()
		h.chromaLog2 = ue()
		h.w = {}
		for list = 0, h.type == 1 and 1 or 0 do
			local n = list == 0 and h.numRef0 or h.numRef1
			local t = {}
			for i = 0, n - 1 do
				local e = { lw = lshift(1, h.lumaLog2), lo = 0, cw1 = lshift(1, h.chromaLog2), co1 = 0, cw2 = lshift(1, h.chromaLog2), co2 = 0, luma = false, chroma = false }
				if u1() == 1 then
					e.lw, e.lo, e.luma = se(), se(), true
				end
				if u1() == 1 then
					e.cw1, e.co1, e.cw2, e.co2, e.chroma = se(), se(), se(), se(), true
				end
				t[i] = e
			end
			h.w[list] = t
		end
	end
	-- reference marking
	if nalRefIdc ~= 0 then
		if h.idr then
			u1()
			h.longTermRef = u1() == 1
		else
			if u1() == 1 then
				local ops = {}
				while true do
					local op = ue()
					if op == 0 then
						break
					end
					local e = { op = op }
					if op == 1 or op == 3 then
						e.diff = ue() + 1
					end
					if op == 2 then
						e.ltpn = ue()
					end
					if op == 3 or op == 6 then
						e.idx = ue()
					end
					if op == 4 then
						e.maxIdx = ue()
					end
					table.insert(ops, e)
				end
				h.mmco = ops
			end
		end
	end
	if pps.cabac and h.type ~= 2 then
		h.cabacInit = ue()
		if h.cabacInit > 2 then
			fail("broken data (bad cabac_init_idc)")
		end
	end
	h.qp = pps.initQp + se()
	h.dbIdc, h.dbA, h.dbB = 0, 0, 0
	if pps.deblockControl then
		h.dbIdc = ue()
		if h.dbIdc ~= 1 then
			h.dbA = se() * 2
			h.dbB = se() * 2
		end
	end
	return h
end

-- picture order count (8.2.1) for a frame
local function computePoc(D, h)
	local sps = h.sps
	local maxFrameNum = lshift(1, sps.log2MaxFrameNum)
	if sps.pocType == 0 then
		if h.idr then
			D.prevPocMsb, D.prevPocLsb = 0, 0
		end
		local maxLsb = lshift(1, sps.log2MaxPocLsb)
		local msb
		if h.pocLsb < D.prevPocLsb and D.prevPocLsb - h.pocLsb >= maxLsb // 2 then
			msb = D.prevPocMsb + maxLsb
		elseif h.pocLsb > D.prevPocLsb and h.pocLsb - D.prevPocLsb > maxLsb // 2 then
			msb = D.prevPocMsb - maxLsb
		else
			msb = D.prevPocMsb
		end
		local top = msb + h.pocLsb
		local bottom = top + h.deltaPocBottom
		h.pocMsb = msb
		return min(top, bottom), top, bottom
	end
	local frameNumOffset
	if h.idr then
		frameNumOffset = 0
	elseif D.prevFrameNum > h.frameNum then
		frameNumOffset = D.prevFrameNumOffset + maxFrameNum
	else
		frameNumOffset = D.prevFrameNumOffset
	end
	h.frameNumOffset = frameNumOffset
	if sps.pocType == 1 then
		local n = #sps.refFrameOffsets
		local absFrameNum = n ~= 0 and (frameNumOffset + h.frameNum) or 0
		if h.refIdc == 0 and absFrameNum > 0 then
			absFrameNum -= 1
		end
		local expected = 0
		if absFrameNum > 0 then
			local cycleCnt = (absFrameNum - 1) // n
			local inCycle = (absFrameNum - 1) % n
			expected = cycleCnt * sps.expectedDeltaPerCycle
			for i = 1, inCycle + 1 do
				expected += sps.refFrameOffsets[i]
			end
		end
		if h.refIdc == 0 then
			expected += sps.offsetForNonRefPic
		end
		local top = expected + h.deltaPoc0
		local bottom = top + sps.offsetForTopToBottom + h.deltaPoc1
		return min(top, bottom), top, bottom
	end
	-- type 2
	local poc
	if h.idr then
		poc = 0
	elseif h.refIdc == 0 then
		poc = 2 * (frameNumOffset + h.frameNum) - 1
	else
		poc = 2 * (frameNumOffset + h.frameNum)
	end
	return poc, poc, poc
end

local function frameNumWrap(D, p, curFrameNum, maxFrameNum)
	if p.frameNum > curFrameNum then
		return p.frameNum - maxFrameNum
	end
	return p.frameNum
end

-- initial reference lists (8.2.4.2) and their modification (8.2.4.3)
local function buildRefLists(D, h)
	local maxFrameNum = lshift(1, h.sps.log2MaxFrameNum)
	local shorts, longs = {}, {}
	for _, p in ipairs(D.dpb) do
		if p.isLong then
			table.insert(longs, p)
		else
			p.picNum = frameNumWrap(D, p, h.frameNum, maxFrameNum)
			table.insert(shorts, p)
		end
	end
	table.sort(longs, function(a, b)
		return a.longIdx < b.longIdx
	end)
	local L0, L1 = {}, {}
	if h.type == 0 then
		table.sort(shorts, function(a, b)
			return a.picNum > b.picNum
		end)
		for _, p in ipairs(shorts) do
			table.insert(L0, p)
		end
		for _, p in ipairs(longs) do
			table.insert(L0, p)
		end
	elseif h.type == 1 then
		local before, after = {}, {}
		for _, p in ipairs(shorts) do
			if p.poc < h.poc then
				table.insert(before, p)
			else
				table.insert(after, p)
			end
		end
		table.sort(before, function(a, b)
			return a.poc > b.poc
		end)
		table.sort(after, function(a, b)
			return a.poc < b.poc
		end)
		for _, p in ipairs(before) do
			table.insert(L0, p)
		end
		for _, p in ipairs(after) do
			table.insert(L0, p)
		end
		for _, p in ipairs(longs) do
			table.insert(L0, p)
		end
		for _, p in ipairs(after) do
			table.insert(L1, p)
		end
		for _, p in ipairs(before) do
			table.insert(L1, p)
		end
		for _, p in ipairs(longs) do
			table.insert(L1, p)
		end
		if #L1 > 1 and #L1 == #L0 then
			local same = true
			for i = 1, #L1 do
				if L1[i] ~= L0[i] then
					same = false
					break
				end
			end
			if same then
				L1[1], L1[2] = L1[2], L1[1]
			end
		end
	end
	local function modify(list, mods, n)
		-- truncate / extend to n entries
		for i = #list, n + 1, -1 do
			list[i] = nil
		end
		if mods then
			local predNum = h.frameNum
			local maxPicNum = maxFrameNum
			for idx, m in ipairs(mods) do
				local refIdx = idx - 1
				local pic
				if m[1] == 0 or m[1] == 1 then
					local d = m[2] + 1
					local noWrap
					if m[1] == 0 then
						noWrap = predNum - d
						if noWrap < 0 then
							noWrap += maxPicNum
						end
					else
						noWrap = predNum + d
						if noWrap >= maxPicNum then
							noWrap -= maxPicNum
						end
					end
					predNum = noWrap
					local picNum = noWrap > h.frameNum and noWrap - maxPicNum or noWrap
					for _, p in ipairs(shorts) do
						if p.picNum == picNum then
							pic = p
							break
						end
					end
				elseif m[1] == 2 then
					for _, p in ipairs(longs) do
						if p.longIdx == m[2] then
							pic = p
							break
						end
					end
				end
				if pic then
					-- insert at refIdx, drop the later duplicate
					table.insert(list, refIdx + 1, pic)
					for i = refIdx + 2, #list do
						if list[i] == pic then
							table.remove(list, i)
							break
						end
					end
					for i = #list, n + 1, -1 do
						list[i] = nil
					end
				end
			end
		end
		-- missing entries: repeat the last one (broken streams only)
		if #list == 0 and n > 0 then
			local any = shorts[1] or longs[1]
			if not any then
				return list
			end
			list[1] = any
		end
		for i = #list + 1, n do
			list[i] = list[i - 1]
		end
		return list
	end
	if h.type ~= 2 then
		L0 = modify(L0, h.mod0, h.numRef0)
		if #L0 == 0 then
			fail("a P or B frame has no reference frame (the video doesn't start with a key frame)")
		end
	end
	if h.type == 1 then
		L1 = modify(L1, h.mod1, h.numRef1)
	end
	return L0, L1
end

-- after a reference picture is decoded (8.2.5)
local function markReference(D, pic, h)
	local sps = h.sps
	local maxFrameNum = lshift(1, sps.log2MaxFrameNum)
	if h.idr then
		for _, p in ipairs(D.dpb) do
			p.isRef = false
		end
		D.dpb = {}
		if h.longTermRef then
			pic.isLong, pic.longIdx = true, 0
			D.maxLongIdx = 0
		else
			pic.isLong = false
			D.maxLongIdx = -1
		end
		pic.isRef = true
		table.insert(D.dpb, pic)
		return
	end
	local currPicNum = h.frameNum
	local function drop(p)
		p.isRef = false
		for i, q in ipairs(D.dpb) do
			if q == p then
				table.remove(D.dpb, i)
				break
			end
		end
	end
	local markedLong = false
	if h.mmco then
		for _, op in ipairs(h.mmco) do
			if op.op == 1 then
				local picNumX = currPicNum - op.diff
				for _, p in ipairs(D.dpb) do
					if not p.isLong and frameNumWrap(D, p, h.frameNum, maxFrameNum) == picNumX then
						drop(p)
						break
					end
				end
			elseif op.op == 2 then
				for _, p in ipairs(D.dpb) do
					if p.isLong and p.longIdx == op.ltpn then
						drop(p)
						break
					end
				end
			elseif op.op == 3 then
				local picNumX = currPicNum - op.diff
				for _, p in ipairs(D.dpb) do
					if p.isLong and p.longIdx == op.idx then
						drop(p)
						break
					end
				end
				for _, p in ipairs(D.dpb) do
					if not p.isLong and frameNumWrap(D, p, h.frameNum, maxFrameNum) == picNumX then
						p.isLong, p.longIdx = true, op.idx
						break
					end
				end
			elseif op.op == 4 then
				D.maxLongIdx = op.maxIdx - 1
				local keep = {}
				for _, p in ipairs(D.dpb) do
					if p.isLong and p.longIdx > D.maxLongIdx then
						p.isRef = false
					else
						table.insert(keep, p)
					end
				end
				D.dpb = keep
			elseif op.op == 5 then
				for _, p in ipairs(D.dpb) do
					p.isRef = false
				end
				D.dpb = {}
				D.maxLongIdx = -1
				h.mmco5 = true
			elseif op.op == 6 then
				for _, p in ipairs(D.dpb) do
					if p.isLong and p.longIdx == op.idx then
						drop(p)
						break
					end
				end
				pic.isLong, pic.longIdx = true, op.idx
				markedLong = true
			end
		end
	else
		-- sliding window
		local shorts, longs = 0, 0
		for _, p in ipairs(D.dpb) do
			if p.isLong then
				longs += 1
			else
				shorts += 1
			end
		end
		if shorts + longs >= max(sps.maxRefFrames, 1) and shorts > 0 then
			local oldest, ow = nil, math.huge
			for _, p in ipairs(D.dpb) do
				if not p.isLong then
					local w = frameNumWrap(D, p, h.frameNum, maxFrameNum)
					if w < ow then
						oldest, ow = p, w
					end
				end
			end
			drop(oldest)
		end
	end
	if not markedLong then
		pic.isLong = false
	end
	pic.isRef = true
	table.insert(D.dpb, pic)
	-- never more than the stream allows
	while #D.dpb > max(sps.maxRefFrames, 1) do
		local oldest, ow = nil, math.huge
		for _, p in ipairs(D.dpb) do
			if not p.isLong then
				local w = frameNumWrap(D, p, h.frameNum, maxFrameNum)
				if w < ow then
					oldest, ow = p, w
				end
			end
		end
		if not oldest then
			break
		end
		drop(oldest)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- macroblock tables

-- B macroblock types 1..21: shape (0 16x16, 1 16x8, 2 8x16), prediction of part 0 and part 1 (1 L0, 2 L1, 3 Bi)
local B_TYPES = {
	{ 0, 1, 0 }, { 0, 2, 0 }, { 0, 3, 0 },
	{ 1, 1, 1 }, { 2, 1, 1 }, { 1, 2, 2 }, { 2, 2, 2 }, { 1, 1, 2 }, { 2, 1, 2 }, { 1, 2, 1 }, { 2, 2, 1 },
	{ 1, 1, 3 }, { 2, 1, 3 }, { 1, 2, 3 }, { 2, 2, 3 }, { 1, 3, 1 }, { 2, 3, 1 }, { 1, 3, 2 }, { 2, 3, 2 }, { 1, 3, 3 }, { 2, 3, 3 },
}
-- sub-macroblock types: shape (0 8x8, 1 8x4, 2 4x8, 3 4x4) and prediction (0 direct, 1 L0, 2 L1, 3 Bi)
local P_SUB = { [0] = { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } }
local B_SUB = { [0] = { 0, 0 }, { 0, 1 }, { 0, 2 }, { 0, 3 }, { 1, 1 }, { 2, 1 }, { 1, 2 }, { 2, 2 }, { 1, 3 }, { 2, 3 }, { 3, 1 }, { 3, 2 }, { 3, 3 } }
local SHAPE_PARTS = { [0] = 1, 2, 2, 4 }

local SIG_OFF = { [0] = 0, 15, 29, 44, 47 }
local ABS_OFF = { [0] = 0, 10, 20, 30, 39 }
local CBF_OFF = { [0] = 0, 4, 8, 12, 16 }
local MVD_INC = { 3, 4, 5, 6, 6, 6, 6, 6 }

local INTRA4_TR -- [blkIdx] -> top-right available inside / above the macroblock (computed below)

-- 6-tap filter at o along step s
local function tap6(P, o, s)
	return readu8(P, o - 2 * s) - 5 * readu8(P, o - s) + 20 * readu8(P, o) + 20 * readu8(P, o + s) - 5 * readu8(P, o + 2 * s) + readu8(P, o + 3 * s)
end
local function clip255(v)
	return v < 0 and 0 or (v > 255 and 255 or v)
end

local PATCH = buffer.create(48 * 48)
local PATCH_STRIDE = 48

-- luma motion compensation of a w x h block at integer (xi, yi) + quarter (xf, yf) from plane P (origin org,
-- stride st, size W x H): writes into dst (stride 16) at dOff
local function lumaMC(P, org, st, W, Hh, xi, yi, xf, yf, w, h, dst, dOff)
	local src, base, ss
	if xi - 2 >= -PADY and yi - 2 >= -PADY and xi + w + 3 < W + PADY and yi + h + 3 < Hh + PADY then
		src, base, ss = P, org + yi * st + xi, st
	else
		-- far outside: copy a clamped patch
		for y = -2, h + 3 do
			local sy = yi + y
			sy = sy < 0 and 0 or (sy > Hh - 1 and Hh - 1 or sy)
			for x = -2, w + 3 do
				local sx = xi + x
				sx = sx < 0 and 0 or (sx > W - 1 and W - 1 or sx)
				writeu8(PATCH, (y + 2) * PATCH_STRIDE + x + 2, readu8(P, org + sy * st + sx))
			end
		end
		src, base, ss = PATCH, 2 * PATCH_STRIDE + 2, PATCH_STRIDE
	end
	for y = 0, h - 1 do
		local so = base + y * ss
		local d = dOff + y * 16
		if xf == 0 and yf == 0 then
			for x = 0, w - 1 do
				writeu8(dst, d + x, readu8(src, so + x))
			end
		elseif yf == 0 then
			for x = 0, w - 1 do
				local o = so + x
				local b = clip255((tap6(src, o, 1) + 16) // 32)
				if xf == 1 then
					b = (readu8(src, o) + b + 1) // 2
				elseif xf == 3 then
					b = (readu8(src, o + 1) + b + 1) // 2
				end
				writeu8(dst, d + x, b)
			end
		elseif xf == 0 then
			for x = 0, w - 1 do
				local o = so + x
				local hh = clip255((tap6(src, o, ss) + 16) // 32)
				if yf == 1 then
					hh = (readu8(src, o) + hh + 1) // 2
				elseif yf == 3 then
					hh = (readu8(src, o + ss) + hh + 1) // 2
				end
				writeu8(dst, d + x, hh)
			end
		elseif xf == 2 or yf == 2 then
			for x = 0, w - 1 do
				local o = so + x
				-- j: the centre half sample from unrounded horizontal halves
				local j = tap6(src, o - 2 * ss, 1) - 5 * tap6(src, o - ss, 1) + 20 * tap6(src, o, 1) + 20 * tap6(src, o + ss, 1)
					- 5 * tap6(src, o + 2 * ss, 1) + tap6(src, o + 3 * ss, 1)
				j = clip255((j + 512) // 1024)
				local v
				if xf == 2 and yf == 2 then
					v = j
				elseif xf == 2 then
					local b = clip255((tap6(src, yf == 1 and o or o + ss, 1) + 16) // 32)
					v = (b + j + 1) // 2
				else
					local hh = clip255((tap6(src, xf == 1 and o or o + 1, ss) + 16) // 32)
					v = (hh + j + 1) // 2
				end
				writeu8(dst, d + x, v)
			end
		else
			for x = 0, w - 1 do
				local o = so + x
				local b = clip255((tap6(src, yf == 1 and o or o + ss, 1) + 16) // 32)
				local hh = clip255((tap6(src, xf == 1 and o or o + 1, ss) + 16) // 32)
				writeu8(dst, d + x, (b + hh + 1) // 2)
			end
		end
	end
end

-- chroma motion compensation (eighth sample, bilinear) into dst (stride 8)
local function chromaMC(P, org, st, W, Hh, xi, yi, xf, yf, w, h, dst, dOff)
	local inside = xi >= -PADC and yi >= -PADC and xi + w + 1 < W + PADC and yi + h + 1 < Hh + PADC
	local w00, w10, w01, w11 = (8 - xf) * (8 - yf), xf * (8 - yf), (8 - xf) * yf, xf * yf
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local a, b, c, d
			if inside then
				local o = org + (yi + y) * st + xi + x
				a, b, c, d = readu8(P, o), readu8(P, o + 1), readu8(P, o + st), readu8(P, o + st + 1)
			else
				local x0, y0 = xi + x, yi + y
				local x1, y1 = x0 + 1, y0 + 1
				x0 = x0 < 0 and 0 or (x0 > W - 1 and W - 1 or x0)
				x1 = x1 < 0 and 0 or (x1 > W - 1 and W - 1 or x1)
				y0 = y0 < 0 and 0 or (y0 > Hh - 1 and Hh - 1 or y0)
				y1 = y1 < 0 and 0 or (y1 > Hh - 1 and Hh - 1 or y1)
				a, b = readu8(P, org + y0 * st + x0), readu8(P, org + y0 * st + x1)
				c, d = readu8(P, org + y1 * st + x0), readu8(P, org + y1 * st + x1)
			end
			writeu8(dst, dOff + y * 8 + x, (w00 * a + w10 * b + w01 * c + w11 * d + 32) // 64)
		end
	end
end

-- inverse transforms, adding the residual to the picture (P, offset o, stride st)
local T16 = table.create(16, 0)
local function idct4Add(C, base, P, o, st)
	for i = 0, 3 do -- rows
		local r = base + i * 4
		local d0, d1, d2, d3 = C[r + 1], C[r + 2], C[r + 3], C[r + 4]
		local e0, e1 = d0 + d2, d0 - d2
		local e2, e3 = (d1 // 2) - d3, d1 + (d3 // 2)
		T16[i * 4 + 1] = e0 + e3
		T16[i * 4 + 2] = e1 + e2
		T16[i * 4 + 3] = e1 - e2
		T16[i * 4 + 4] = e0 - e3
	end
	for j = 0, 3 do -- columns
		local f0, f1, f2, f3 = T16[j + 1], T16[j + 5], T16[j + 9], T16[j + 13]
		local g0, g1 = f0 + f2, f0 - f2
		local g2, g3 = (f1 // 2) - f3, f1 + (f3 // 2)
		local q = o + j
		writeu8(P, q, clip255(readu8(P, q) + (g0 + g3 + 32) // 64))
		q += st
		writeu8(P, q, clip255(readu8(P, q) + (g1 + g2 + 32) // 64))
		q += st
		writeu8(P, q, clip255(readu8(P, q) + (g1 - g2 + 32) // 64))
		q += st
		writeu8(P, q, clip255(readu8(P, q) + (g0 - g3 + 32) // 64))
	end
end
local function dcAdd4(dc, P, o, st)
	local v = (dc + 32) // 64
	if v == 0 then
		return
	end
	for y = 0, 3 do
		local q = o + y * st
		for x = 0, 3 do
			writeu8(P, q + x, clip255(readu8(P, q + x) + v))
		end
	end
end
local T64 = table.create(64, 0)
local function idct8Add(C, base, P, o, st)
	local function pass(get, put)
		for k = 0, 7 do
			local d0, d1, d2, d3, d4, d5, d6, d7 = get(k, 0), get(k, 1), get(k, 2), get(k, 3), get(k, 4), get(k, 5), get(k, 6), get(k, 7)
			local e0 = d0 + d4
			local e1 = -d3 + d5 - d7 - (d7 // 2)
			local e2 = d0 - d4
			local e3 = d1 + d7 - d3 - (d3 // 2)
			local e4 = (d2 // 2) - d6
			local e5 = -d1 + d7 + d5 + (d5 // 2)
			local e6 = d2 + (d6 // 2)
			local e7 = d3 + d5 + d1 + (d1 // 2)
			local f0 = e0 + e6
			local f1 = e1 + (e7 // 4)
			local f2 = e2 + e4
			local f3 = e3 + (e5 // 4)
			local f4 = e2 - e4
			local f5 = (e3 // 4) - e5
			local f6 = e0 - e6
			local f7 = e7 - (e1 // 4)
			put(k, 0, f0 + f7)
			put(k, 1, f2 + f5)
			put(k, 2, f4 + f3)
			put(k, 3, f6 + f1)
			put(k, 4, f6 - f1)
			put(k, 5, f4 - f3)
			put(k, 6, f2 - f5)
			put(k, 7, f0 - f7)
		end
	end
	-- rows: element (row k, column n)
	pass(function(k, n)
		return C[base + k * 8 + n + 1]
	end, function(k, n, v)
		T64[k * 8 + n + 1] = v
	end)
	-- columns: element (column k, row n)
	pass(function(k, n)
		return T64[n * 8 + k + 1]
	end, function(k, n, v)
		local q = o + n * st + k
		writeu8(P, q, clip255(readu8(P, q) + (v + 32) // 64))
	end)
end

------------------------------------------------------------------------------------------------------------------------
-- one slice

local sliceCounter = 0

local function decodeSlice(D, h, pic)
	local pps, sps = h.pps, h.sps
	local mbw, mbh = D.mbw, D.mbh
	local W4, W2 = D.W4, D.W2
	local W, Hh = mbw * 16, mbh * 16
	sliceCounter += 1
	local sliceNum = sliceCounter
	local cabac = pps.cabac
	local stype = h.type
	local isB = stype == 1
	local isI = stype == 2
	local L0, L1 = {}, {}
	if not isI then
		L0, L1 = buildRefLists(D, h)
	end
	local numRef0, numRef1 = h.numRef0, h.numRef1
	local mbSlice, mbKind, mbQp, mbT8, mbCbp, mbChroma, mbDcCbf = D.mbSlice, D.mbKind, D.mbQp, D.mbT8, D.mbCbp, D.mbChroma, D.mbDcCbf
	local nnz, coef, imode = D.nnz, D.coef, D.imode
	local nnzU, nnzV = D.nnzU, D.nnzV
	local mvd0x, mvd0y, mvd1x, mvd1y = D.mvd0x, D.mvd0y, D.mvd1x, D.mvd1y
	D.isDirect = D.isDirect or table.create(#nnz, false)
	local isDirect = D.isDirect
	local mv0x, mv0y, mv1x, mv1y = pic.mv0x, pic.mv0y, pic.mv1x, pic.mv1y
	local ref0, ref1, rp0, rp1 = pic.ref0, pic.ref1, pic.rp0, pic.rp1
	local picIntra = pic.intra
	local Yp, Up, Vp, ys, cs, yo, co = pic.Y, pic.U, pic.V, pic.ys, pic.cs, pic.yo, pic.co
	local constrainedIntra = pps.constrainedIntra
	local t8mode = pps.transform8x8
	local ls4, ls8 = pps.ls4, pps.ls8
	local qpOff1, qpOff2 = pps.chromaQpOffset, pps.chromaQpOffset2
	local direct8x8 = sps.direct8x8
	local col = isB and L1[1] or nil

	-- weights
	local logWDl, logWDc, wtab = 0, 0, nil
	local implicit = isB and pps.weightedBipred == 2
	if h.w then
		logWDl, logWDc, wtab = h.lumaLog2, h.chromaLog2, h.w
	end
	local implicitCache = {}
	local function implicitWeights(r0, r1)
		local key = r0 * 64 + r1
		local c = implicitCache[key]
		if c then
			return c
		end
		local p0, p1 = L0[r0 + 1], L1[r1 + 1]
		local w0, w1 = 32, 32
		if not p0.isLong and not p1.isLong then
			local tb = max(-128, min(127, h.poc - p0.poc))
			local td = max(-128, min(127, p1.poc - p0.poc))
			if td ~= 0 then
				local tdh = td >= 0 and td // 2 or -((-td) // 2)
				local num = 16384 + abs(tdh)
				local tx = num // td
				if (num % td ~= 0) and ((num < 0) ~= (td < 0)) then
					tx += 1 -- C division truncates toward zero
				end
				local dsf = max(-1024, min(1023, (tb * tx + 32) // 64))
				local s = dsf // 4
				if s >= -64 and s <= 128 then
					w0, w1 = 64 - s, s
				end
			end
		end
		c = { w0, w1 }
		implicitCache[key] = c
		return c
	end

	-- per-slice deblocking info stays with each macroblock
	local dbIdc, dbA, dbB = h.dbIdc, h.dbA, h.dbB

	local mbAddr, mbx, mby = 0, 0, 0
	local curIntra = false
	local qp = h.qp
	local prevQpDeltaNZ = false
	local cbpL, cbpC = 0, 0
	local t8 = false

	local function availMb(n)
		return n >= 0 and mbSlice[n + 1] == sliceNum
	end
	-- the macroblock holding global 4x4 block (gx, gy), or -1 when outside / unavailable (not the current one)
	local function mbOfBlock(gx, gy)
		if gx < 0 or gy < 0 or gx >= W4 then
			return -1
		end
		local n = (gy // 4) * mbw + gx // 4
		if n == mbAddr then
			return n
		end
		if mbSlice[n + 1] ~= sliceNum or n > mbAddr then
			return -1
		end
		return n
	end
	local function isSkipKind(k)
		return k == K_PSKIP or k == K_BSKIP
	end

	------------------------------------------------------------------------------------------------------------------
	-- entropy: CAVLC

	local function cavlcNC(gx, gy, plane)
		-- nC from the left and top blocks' coefficient counts
		local nA, nB
		local grid, stride = nnz, W4
		if plane == 1 then
			grid, stride = nnzU, W2
		elseif plane == 2 then
			grid, stride = nnzV, W2
		end
		local sh = plane == 0 and 4 or 2
		local function mbOf(x, y)
			if x < 0 or y < 0 then
				return -1
			end
			local n = (y // sh) * mbw + x // sh
			if n == mbAddr then
				return n
			end
			if mbSlice[n + 1] ~= sliceNum then
				return -1
			end
			return n
		end
		local a = mbOf(gx - 1, gy)
		if a >= 0 then
			nA = grid[gy * stride + gx]
		end
		local b = mbOf(gx, gy - 1)
		if b >= 0 then
			nB = grid[(gy - 1) * stride + gx + 1]
		end
		if nA and nB then
			return (nA + nB + 1) // 2
		end
		return nA or nB or 0
	end

	-- CAVLC residual block: levels go to out[outBase + scan position] (scan index, not raster); returns TotalCoeff
	local levelTmp = table.create(16, 0)
	local runTmp = table.create(16, 0)
	local function cavlcResidual(nC, startIdx, endIdx, maxNum, out, outBase)
		local token
		if nC == -1 then
			token = readVlc(CHROMA_DC_TOKEN)
		else
			local t = nC < 2 and 0 or (nC < 4 and 1 or (nC < 8 and 2 or 3))
			token = readVlc(COEFF_TOKEN[t])
		end
		local total, trailing = rshift(token, 2), band(token, 3)
		if total == 0 then
			return 0
		end
		if total > maxNum then
			fail("broken data (too many coefficients)")
		end
		local suffixLength = (total > 10 and trailing < 3) and 1 or 0
		for i = 1, total do
			if i <= trailing then
				levelTmp[i] = u1() == 1 and -1 or 1
			else
				local prefix = 0
				while u1() == 0 do
					prefix += 1
					if prefix > 32 then
						fail("broken data (bad coefficient)")
					end
				end
				local levelCode = lshift(min(15, prefix), suffixLength)
				if suffixLength > 0 or prefix >= 14 then
					local size
					if prefix == 14 and suffixLength == 0 then
						size = 4
					elseif prefix >= 15 then
						size = prefix - 3
					else
						size = suffixLength
					end
					if size > 0 then
						if size > 16 then
							levelCode += u(size - 16) * 65536 + u(16)
						else
							levelCode += u(size)
						end
					end
				end
				if prefix >= 15 and suffixLength == 0 then
					levelCode += 15
				end
				if prefix >= 16 then
					levelCode += lshift(1, prefix - 3) - 4096
				end
				if i == trailing + 1 and trailing < 3 then
					levelCode += 2
				end
				local level
				if levelCode % 2 == 0 then
					level = (levelCode + 2) // 2
				else
					level = (-levelCode - 1) // 2
				end
				levelTmp[i] = level
				if suffixLength == 0 then
					suffixLength = 1
				end
				if abs(level) > lshift(3, suffixLength - 1) and suffixLength < 6 then
					suffixLength += 1
				end
			end
		end
		local zerosLeft = 0
		if total < endIdx - startIdx + 1 then
			if nC == -1 then
				zerosLeft = readVlc(CHROMA_DC_TZ[total])
			else
				zerosLeft = readVlc(TOTAL_ZEROS[total])
			end
		end
		for i = 1, total - 1 do
			if zerosLeft > 0 then
				local r = readVlc(RUN_BEFORE[min(zerosLeft, 7)])
				runTmp[i] = r
				zerosLeft -= r
			else
				runTmp[i] = 0
			end
		end
		runTmp[total] = zerosLeft
		local coeffNum = -1
		for i = total, 1, -1 do
			coeffNum += runTmp[i] + 1
			if startIdx + coeffNum > endIdx then
				fail("broken data (coefficients past the end of a block)")
			end
			out[outBase + startIdx + coeffNum] = levelTmp[i]
		end
		return total
	end

	------------------------------------------------------------------------------------------------------------------
	-- entropy: CABAC

	local function cabacUEG0Bypass()
		local k, v = 0, 0
		while decodeBypass() == 1 do
			v += lshift(1, k)
			k += 1
			if k > 30 then
				fail("broken data (bad coefficient)")
			end
		end
		while k > 0 do
			k -= 1
			v += lshift(decodeBypass(), k)
		end
		return v
	end

	-- residual block: levels to out[outBase + scan index]; returns the number of coefficients
	local sigPos = table.create(64, 0)
	local function cabacResidual(cat, maxNum, out, outBase, startIdx)
		local sigBase, lastBase, absBase
		if cat == 5 then
			sigBase, lastBase, absBase = 402, 417, 426
		else
			sigBase, lastBase, absBase = 105 + SIG_OFF[cat], 166 + SIG_OFF[cat], 227 + ABS_OFF[cat]
		end
		local count = 0
		local numCoeff = maxNum
		local i = 0
		local ended = false
		while i < numCoeff - 1 do
			local si, li
			if cat == 5 then
				si, li = SIG8[i + 1], LAST8[i + 1]
			elseif cat == 3 then
				si = i < 2 and i or 2
				li = si
			else
				si, li = i, i
			end
			if decodeBin(sigBase + si) == 1 then
				count += 1
				sigPos[count] = i
				if decodeBin(lastBase + li) == 1 then
					ended = true
					break
				end
			end
			i += 1
		end
		if not ended then
			count += 1
			sigPos[count] = numCoeff - 1
		end
		local gt1, eq1 = 0, 0
		local maxGt = cat == 3 and 3 or 4
		for k = count, 1, -1 do
			local inc0 = gt1 ~= 0 and 0 or min(4, 1 + eq1)
			local absm1 = 0
			if decodeBin(absBase + inc0) == 1 then
				local inc = 5 + min(maxGt, gt1)
				absm1 = 1
				while absm1 < 14 and decodeBin(absBase + inc) == 1 do
					absm1 += 1
				end
				if absm1 == 14 then
					absm1 += cabacUEG0Bypass()
				end
			end
			if absm1 == 0 then
				eq1 += 1
			else
				gt1 += 1
			end
			local v = absm1 + 1
			if decodeBypass() == 1 then
				v = -v
			end
			out[outBase + startIdx + sigPos[k]] = v
		end
		return count
	end

	-- condition terms for coded_block_flag of a luma 4x4 block neighbour (global gx, gy)
	local function cbfLumaTerm(gx, gy)
		local n = mbOfBlock(gx, gy)
		if n < 0 then
			return curIntra and 1 or 0
		end
		local k = mbKind[n + 1]
		if k == K_PCM then
			return 1
		end
		return nnz[gy * W4 + gx + 1] > 0 and 1 or 0
	end
	local function cbfChromaTerm(plane, cx, cy)
		if cx < 0 or cy < 0 then
			return curIntra and 1 or 0
		end
		local n = (cy // 2) * mbw + cx // 2
		if n ~= mbAddr and (mbSlice[n + 1] ~= sliceNum or n > mbAddr) then
			return curIntra and 1 or 0
		end
		local k = mbKind[n + 1]
		if k == K_PCM then
			return 1
		end
		if n ~= mbAddr and mbCbp[n + 1] // 16 ~= 2 then
			return 0
		end
		local grid = plane == 1 and nnzU or nnzV
		return grid[cy * W2 + cx + 1] > 0 and 1 or 0
	end
	local function cbfDcTerm(n, bit)
		if n < 0 then
			return curIntra and 1 or 0
		end
		local k = mbKind[n + 1]
		if k == K_PCM then
			return 1
		end
		return band(mbDcCbf[n + 1], bit) ~= 0 and 1 or 0
	end
	local function mbLeft()
		return mbx > 0 and availMb(mbAddr - 1) and mbAddr - 1 or -1
	end
	local function mbTop()
		return mby > 0 and availMb(mbAddr - mbw) and mbAddr - mbw or -1
	end

	------------------------------------------------------------------------------------------------------------------
	-- syntax elements (CABAC versions need the neighbours)

	local function cabacSkipFlag()
		local a, b = mbLeft(), mbTop()
		local inc = (a >= 0 and not isSkipKind(mbKind[a + 1]) and 1 or 0) + (b >= 0 and not isSkipKind(mbKind[b + 1]) and 1 or 0)
		return decodeBin((isB and 24 or 11) + inc) == 1
	end

	-- intra mb_type bins (I slice prefix ctx 3 with neighbour inc, or the P / B suffix at `base`)
	local function cabacIntraType(base, inSliceI)
		local first
		if inSliceI then
			local a, b = mbLeft(), mbTop()
			local inc = 0
			if a >= 0 and (mbKind[a + 1] == K_I16 or mbKind[a + 1] == K_PCM) then
				inc += 1
			end
			if b >= 0 and (mbKind[b + 1] == K_I16 or mbKind[b + 1] == K_PCM) then
				inc += 1
			end
			first = decodeBin(base + inc)
		else
			first = decodeBin(base)
		end
		if first == 0 then
			return 0 -- I_NxN
		end
		if decodeTerminate() == 1 then
			return 25 -- I_PCM
		end
		local s = inSliceI and 3 or 1 -- base offsets of the later bins
		local mt = 1
		mt += 12 * decodeBin(base + s) -- luma cbp 15
		if decodeBin(base + s + 1) == 1 then -- chroma
			mt += 4 + 4 * decodeBin(inSliceI and base + 5 or base + 2)
		end
		local p = inSliceI and 6 or 3
		mt += 2 * decodeBin(base + p)
		mt += decodeBin(base + p + (inSliceI and 1 or 0))
		return mt
	end

	local function readMbType()
		if not cabac then
			return ue()
		end
		if isI then
			return cabacIntraType(3, true)
		elseif not isB then
			if decodeBin(14) == 0 then
				if decodeBin(15) == 0 then
					return 3 * decodeBin(16) -- 0: 16x16, 3: 8x8
				end
				return 2 - decodeBin(17) -- 1: 16x8, 2: 8x16
			end
			return 5 + cabacIntraType(17, false)
		else
			local a, b = mbLeft(), mbTop()
			local inc = 0
			if a >= 0 and mbKind[a + 1] ~= K_BSKIP and mbKind[a + 1] ~= K_BDIRECT then
				inc += 1
			end
			if b >= 0 and mbKind[b + 1] ~= K_BSKIP and mbKind[b + 1] ~= K_BDIRECT then
				inc += 1
			end
			if decodeBin(27 + inc) == 0 then
				return 0
			end
			if decodeBin(27 + 3) == 0 then
				return 1 + decodeBin(27 + 5)
			end
			local bits = decodeBin(27 + 4) * 8
			bits += decodeBin(27 + 5) * 4
			bits += decodeBin(27 + 5) * 2
			bits += decodeBin(27 + 5)
			if bits < 8 then
				return bits + 3
			elseif bits == 13 then
				return 23 + cabacIntraType(32, false)
			elseif bits == 14 then
				return 11
			elseif bits == 15 then
				return 22
			end
			bits = bits * 2 + decodeBin(27 + 5)
			return bits - 4
		end
	end

	local function readSubType()
		if not cabac then
			return ue()
		end
		if not isB then
			if decodeBin(21) == 1 then
				return 0
			end
			if decodeBin(22) == 0 then
				return 1
			end
			return decodeBin(23) == 1 and 2 or 3
		end
		if decodeBin(36) == 0 then
			return 0
		end
		if decodeBin(37) == 0 then
			return 1 + decodeBin(39)
		end
		local t = 3
		if decodeBin(38) == 1 then
			if decodeBin(39) == 1 then
				return 11 + decodeBin(39)
			end
			t += 4
		end
		t += 2 * decodeBin(39)
		t += decodeBin(39)
		return t
	end

	-- neighbour 4x4 block values of a list for prediction: returns available, refIdx, mvx, mvy (gx, gy global)
	local partOrd = table.create(16, 0) -- partition order of each 4x4 block of the current macroblock
	local curOrd = 0
	local function neighbour(list, gx, gy, needDone)
		if gx < 0 or gy < 0 or gx >= W4 then
			return false, -1, 0, 0
		end
		local n = (gy // 4) * mbw + gx // 4
		if n == mbAddr then
			if needDone then
				local o = partOrd[(gy % 4) * 4 + gx % 4 + 1]
				if o >= curOrd then
					return false, -1, 0, 0
				end
			end
		elseif n > mbAddr or mbSlice[n + 1] ~= sliceNum then
			return false, -1, 0, 0
		end
		if n ~= mbAddr and picIntra[n + 1] then
			return true, -1, 0, 0
		end
		local i = gy * W4 + gx + 1
		if list == 0 then
			local r = ref0[i]
			if r < 0 then
				return true, -1, 0, 0
			end
			return true, r, mv0x[i], mv0y[i]
		end
		local r = ref1[i]
		if r < 0 then
			return true, -1, 0, 0
		end
		return true, r, mv1x[i], mv1y[i]
	end

	-- motion vector prediction (8.4.1.3) for a partition at (bx, by) of bw x bh 4x4 blocks; shape 1 = 16x8, 2 = 8x16
	local function mvPred(list, bx, by, bw, bh, refIdx, shape, partIdx)
		local gx, gy = mbx * 4 + bx, mby * 4 + by
		local aAv, ra, ax, ay = neighbour(list, gx - 1, gy, true)
		local bAv, rb, bx2, by2 = neighbour(list, gx, gy - 1, true)
		local cAv, rc, cx, cy = neighbour(list, gx + bw, gy - 1, true)
		if not cAv then
			cAv, rc, cx, cy = neighbour(list, gx - 1, gy - 1, true)
		end
		if not bAv and not cAv and aAv then
			rb, bx2, by2 = ra, ax, ay
			rc, cx, cy = ra, ax, ay
		end
		if shape == 1 then
			if partIdx == 0 and rb == refIdx then
				return bx2, by2
			elseif partIdx == 1 and ra == refIdx then
				return ax, ay
			end
		elseif shape == 2 then
			if partIdx == 0 and ra == refIdx then
				return ax, ay
			elseif partIdx == 1 and rc == refIdx then
				return cx, cy
			end
		end
		local matches = (ra == refIdx and 1 or 0) + (rb == refIdx and 1 or 0) + (rc == refIdx and 1 or 0)
		if matches == 1 then
			if ra == refIdx then
				return ax, ay
			elseif rb == refIdx then
				return bx2, by2
			end
			return cx, cy
		end
		-- median
		local mx = ax + bx2 + cx - min(ax, bx2, cx) - max(ax, bx2, cx)
		local my = ay + by2 + cy - min(ay, by2, cy) - max(ay, by2, cy)
		return mx, my
	end

	-- CABAC: sum of the neighbours' absolute mvd (A and B of the partition)
	local function mvdSum(list, comp, gx, gy)
		local s = 0
		for k = 1, 2 do
			local x, y = gx, gy
			if k == 1 then
				x -= 1
			else
				y -= 1
			end
			local n = mbOfBlock(x, y)
			if n >= 0 then
				local i = y * W4 + x + 1
				local t = list == 0 and (comp == 0 and mvd0x or mvd0y) or (comp == 0 and mvd1x or mvd1y)
				if n == mbAddr then
					local o = partOrd[(y % 4) * 4 + x % 4 + 1]
					if o < curOrd then
						s += t[i]
					end
				elseif not picIntra[n + 1] then
					s += t[i]
				end
			end
		end
		return s
	end
	local function readMvd(list, comp, gx, gy)
		if not cabac then
			return se()
		end
		local base = comp == 0 and 40 or 47
		local sum = mvdSum(list, comp, gx, gy)
		local inc = sum < 3 and 0 or (sum > 32 and 2 or 1)
		if decodeBin(base + inc) == 0 then
			return 0
		end
		local v = 1
		while v < 9 and decodeBin(base + MVD_INC[v]) == 1 do
			v += 1
		end
		if v >= 9 then
			local k = 3
			while decodeBypass() == 1 do
				v += lshift(1, k)
				k += 1
				if k > 30 then
					fail("broken data (bad motion vector)")
				end
			end
			while k > 0 do
				k -= 1
				v += lshift(decodeBypass(), k)
			end
		end
		if decodeBypass() == 1 then
			return -v
		end
		return v
	end

	local function readRefIdx(list, gx, gy, numRef)
		if numRef <= 1 then
			return 0
		end
		if not cabac then
			if numRef == 2 then
				return 1 - u1()
			end
			local r = ue()
			if r >= numRef then
				fail("broken data (reference index out of range)")
			end
			return r
		end
		local inc = 0
		for k = 1, 2 do
			local x, y = gx, gy
			if k == 1 then
				x -= 1
			else
				y -= 1
			end
			local n = mbOfBlock(x, y)
			if n >= 0 then
				local i = y * W4 + x + 1
				local ok = true
				if n == mbAddr then
					ok = partOrd[(y % 4) * 4 + x % 4 + 1] < curOrd
				elseif picIntra[n + 1] or isSkipKind(mbKind[n + 1]) then
					ok = false
				end
				if ok and not isDirect[i] then
					local r = list == 0 and ref0[i] or ref1[i]
					if r > 0 then
						inc += k
					end
				end
			end
		end
		if decodeBin(54 + inc) == 0 then
			return 0
		end
		if decodeBin(54 + 4) == 0 then
			return 1
		end
		local r = 2
		while decodeBin(54 + 5) == 1 do
			r += 1
			if r > 32 then
				fail("broken data (reference index out of range)")
			end
		end
		return r
	end

	local function readCbp(intraNxN)
		if not cabac then
			local k = ue()
			if k > 47 then
				fail("broken data (bad coded block pattern)")
			end
			return intraNxN and CBP_INTRA[k + 1] or CBP_INTER[k + 1]
		end
		local a, b = mbLeft(), mbTop()
		local cbp = 0
		for b8 = 0, 3 do
			local bx8, by8 = b8 % 2, b8 // 2
			local condA, condB
			-- left 8x8
			if bx8 == 1 then
				condA = band(cbp, lshift(1, b8 - 1)) == 0 and 1 or 0
			elseif a < 0 then
				condA = 0
			else
				local k = mbKind[a + 1]
				if k == K_PCM then
					condA = 0
				elseif isSkipKind(k) then
					condA = 1
				else
					condA = band(mbCbp[a + 1], lshift(1, b8 + 1)) == 0 and 1 or 0
				end
			end
			if by8 == 1 then
				condB = band(cbp, lshift(1, b8 - 2)) == 0 and 1 or 0
			elseif b < 0 then
				condB = 0
			else
				local k = mbKind[b + 1]
				if k == K_PCM then
					condB = 0
				elseif isSkipKind(k) then
					condB = 1
				else
					condB = band(mbCbp[b + 1], lshift(1, b8 + 2)) == 0 and 1 or 0
				end
			end
			cbp += lshift(decodeBin(73 + condA + 2 * condB), b8)
		end
		local function chromaCond(n, need2)
			if n < 0 then
				return 0
			end
			local k = mbKind[n + 1]
			if k == K_PCM then
				return 1
			end
			if isSkipKind(k) then
				return 0
			end
			local c = mbCbp[n + 1] // 16
			if need2 then
				return c == 2 and 1 or 0
			end
			return c ~= 0 and 1 or 0
		end
		if decodeBin(77 + chromaCond(a, false) + 2 * chromaCond(b, false)) == 1 then
			cbp += 16 * (1 + decodeBin(77 + 4 + chromaCond(a, true) + 2 * chromaCond(b, true)))
		end
		return cbp
	end

	local function readQpDelta()
		if not cabac then
			return se()
		end
		if decodeBin(60 + (prevQpDeltaNZ and 1 or 0)) == 0 then
			return 0
		end
		local k = 1
		if decodeBin(62) == 1 then
			k = 2
			while decodeBin(63) == 1 do
				k += 1
				if k > 200 then
					fail("broken data (bad qp change)")
				end
			end
		end
		if k % 2 == 1 then
			return (k + 1) // 2
		end
		return -(k // 2)
	end

	local function readT8Flag()
		if not cabac then
			return u1() == 1
		end
		local a, b = mbLeft(), mbTop()
		local inc = (a >= 0 and mbT8[a + 1] and 1 or 0) + (b >= 0 and mbT8[b + 1] and 1 or 0)
		return decodeBin(399 + inc) == 1
	end

	local function readChromaMode()
		if not cabac then
			local m = ue()
			if m > 3 then
				fail("broken data (bad chroma mode)")
			end
			return m
		end
		local a, b = mbLeft(), mbTop()
		local inc = 0
		for _, n in ipairs({ a, b }) do
			if n >= 0 then
				local k = mbKind[n + 1]
				if k <= K_I16 and mbChroma[n + 1] ~= 0 then
					inc += 1
				end
			end
		end
		if decodeBin(64 + inc) == 0 then
			return 0
		end
		if decodeBin(64 + 3) == 0 then
			return 1
		end
		return decodeBin(64 + 3) == 0 and 2 or 3
	end

	local function readPrevIntraFlag()
		if not cabac then
			return u1() == 1
		end
		return decodeBin(68) == 1
	end
	local function readRemIntra()
		if not cabac then
			return u(3)
		end
		local v = decodeBin(69)
		v += 2 * decodeBin(69)
		v += 4 * decodeBin(69)
		return v
	end

	-- intra prediction mode of a neighbouring 4x4 block for the predicted mode (2 = DC when not NxN)
	local function intraModeOf(gx, gy)
		local n = mbOfBlock(gx, gy)
		if n < 0 then
			return nil
		end
		local k = mbKind[n + 1]
		if n ~= mbAddr and k > K_PCM and constrainedIntra then
			return nil
		end
		if k == K_I4 or k == K_I8 then
			return imode[gy * W4 + gx + 1]
		end
		return 2
	end
	local function predictedIntraMode(gx, gy)
		local a = intraModeOf(gx - 1, gy)
		local b = intraModeOf(gx, gy - 1)
		if a == nil or b == nil then
			return 2
		end
		return min(a, b)
	end

	------------------------------------------------------------------------------------------------------------------
	-- intra prediction (on the picture, before the deblocking filter)

	-- can intra prediction use the samples of global 4x4 block (gx, gy)? (inside the current MB: decoded before `ord`)
	local function intraAvail(gx, gy, ordOf, ord)
		local n = mbOfBlock(gx, gy)
		if n < 0 then
			return false
		end
		if n == mbAddr then
			return ordOf((gx % 4) + 4 * (gy % 4)) < ord
		end
		if constrainedIntra and not picIntra[n + 1] then
			return false
		end
		return true
	end
	local function ord4(pos)
		return BLK_AT[pos]
	end
	local function ord8(pos)
		return (pos // 8) * 2 + (pos % 4) // 2
	end

	local PT = table.create(17, 0) -- top samples p[x, -1], x = -1..15 at PT[x + 2]
	local PL = table.create(17, 0) -- left samples p[-1, y], y = -1..15 at PL[y + 2]
	local function T(x)
		return PT[x + 2]
	end
	local function L(y)
		return PL[y + 2]
	end

	-- the 9 directional 4x4 / 8x8 modes (n = 4 or 8) from PT / PL into the plane at o
	local function predDirectional(mode, n, o, haveTop, haveLeft)
		local P, st = Yp, ys
		local function S(x, y, v)
			writeu8(P, o + y * st + x, v)
		end
		if mode == 0 then
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					S(x, y, T(x))
				end
			end
		elseif mode == 1 then
			for y = 0, n - 1 do
				local v = L(y)
				for x = 0, n - 1 do
					S(x, y, v)
				end
			end
		elseif mode == 2 then
			local sum, cnt = 0, 0
			if haveTop then
				for x = 0, n - 1 do
					sum += T(x)
				end
				cnt += n
			end
			if haveLeft then
				for y = 0, n - 1 do
					sum += L(y)
				end
				cnt += n
			end
			local v = cnt > 0 and (sum + cnt // 2) // cnt or 128
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					S(x, y, v)
				end
			end
		elseif mode == 3 then -- diagonal down left
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local v
					if x == n - 1 and y == n - 1 then
						v = (T(2 * n - 2) + 3 * T(2 * n - 1) + 2) // 4
					else
						v = (T(x + y) + 2 * T(x + y + 1) + T(x + y + 2) + 2) // 4
					end
					S(x, y, v)
				end
			end
		elseif mode == 4 then -- diagonal down right
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local v
					if x > y then
						v = (T(x - y - 2) + 2 * T(x - y - 1) + T(x - y) + 2) // 4
					elseif x < y then
						v = (L(y - x - 2) + 2 * L(y - x - 1) + L(y - x) + 2) // 4
					else
						v = (T(0) + 2 * T(-1) + L(0) + 2) // 4
					end
					S(x, y, v)
				end
			end
		elseif mode == 5 then -- vertical right
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local z = 2 * x - y
					local v
					if z >= 0 and z % 2 == 0 then
						v = (T(x - (y // 2) - 1) + T(x - (y // 2)) + 1) // 2
					elseif z >= 0 then
						v = (T(x - (y // 2) - 2) + 2 * T(x - (y // 2) - 1) + T(x - (y // 2)) + 2) // 4
					elseif z == -1 then
						v = (L(0) + 2 * L(-1) + T(0) + 2) // 4
					else
						v = (L(y - 2 * x - 1) + 2 * L(y - 2 * x - 2) + L(y - 2 * x - 3) + 2) // 4
					end
					S(x, y, v)
				end
			end
		elseif mode == 6 then -- horizontal down
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local z = 2 * y - x
					local v
					if z >= 0 and z % 2 == 0 then
						v = (L(y - (x // 2) - 1) + L(y - (x // 2)) + 1) // 2
					elseif z >= 0 then
						v = (L(y - (x // 2) - 2) + 2 * L(y - (x // 2) - 1) + L(y - (x // 2)) + 2) // 4
					elseif z == -1 then
						v = (L(0) + 2 * L(-1) + T(0) + 2) // 4
					else
						v = (T(x - 2 * y - 1) + 2 * T(x - 2 * y - 2) + T(x - 2 * y - 3) + 2) // 4
					end
					S(x, y, v)
				end
			end
		elseif mode == 7 then -- vertical left
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local v
					if y % 2 == 0 then
						v = (T(x + (y // 2)) + T(x + (y // 2) + 1) + 1) // 2
					else
						v = (T(x + (y // 2)) + 2 * T(x + (y // 2) + 1) + T(x + (y // 2) + 2) + 2) // 4
					end
					S(x, y, v)
				end
			end
		else -- horizontal up
			local lim = 2 * n - 3
			for y = 0, n - 1 do
				for x = 0, n - 1 do
					local z = x + 2 * y
					local v
					if z < lim and z % 2 == 0 then
						v = (L(y + (x // 2)) + L(y + (x // 2) + 1) + 1) // 2
					elseif z < lim then
						v = (L(y + (x // 2)) + 2 * L(y + (x // 2) + 1) + L(y + (x // 2) + 2) + 2) // 4
					elseif z == lim then
						v = (L(n - 2) + 3 * L(n - 1) + 2) // 4
					else
						v = L(n - 1)
					end
					S(x, y, v)
				end
			end
		end
	end

	local function predIntra4(blk, mode)
		local bx, by = BLK_X[blk + 1], BLK_Y[blk + 1]
		local gx, gy = mbx * 4 + bx, mby * 4 + by
		local o = yo + (gy * 4) * ys + gx * 4
		local haveTop = intraAvail(gx, gy - 1, ord4, blk)
		local haveLeft = intraAvail(gx - 1, gy, ord4, blk)
		local haveTL = intraAvail(gx - 1, gy - 1, ord4, blk)
		local haveTR
		if by == 0 then
			haveTR = intraAvail(gx + 1, gy - 1, ord4, blk)
		elseif bx == 3 then
			haveTR = false
		else
			haveTR = BLK_AT[(bx + 1) + 4 * (by - 1)] < blk and (not constrainedIntra or true)
		end
		if haveTop then
			for x = 0, 3 do
				PT[x + 2] = readu8(Yp, o - ys + x)
			end
			if haveTR then
				for x = 4, 7 do
					PT[x + 2] = readu8(Yp, o - ys + x)
				end
			else
				for x = 4, 7 do
					PT[x + 2] = PT[5]
				end
			end
		end
		if haveLeft then
			for y = 0, 3 do
				PL[y + 2] = readu8(Yp, o + y * ys - 1)
			end
		end
		if haveTL then
			local v = readu8(Yp, o - ys - 1)
			PT[1], PL[1] = v, v
		end
		predDirectional(mode, 4, o, haveTop, haveLeft)
	end

	local function predIntra8(b8, mode)
		local bx, by = (b8 % 2) * 2, (b8 // 2) * 2
		local gx, gy = mbx * 4 + bx, mby * 4 + by
		local o = yo + (gy * 4) * ys + gx * 4
		local haveTop = intraAvail(gx, gy - 1, ord8, b8)
		local haveLeft = intraAvail(gx - 1, gy, ord8, b8)
		local haveTL = intraAvail(gx - 1, gy - 1, ord8, b8)
		local haveTR
		if by == 0 then
			haveTR = intraAvail(gx + 2, gy - 1, ord8, b8)
		else
			haveTR = b8 == 2 -- the top-right 8x8 of the bottom-left one is already decoded
		end
		-- raw samples into a scratch, then the reference filter into PT / PL
		local top, left = table.create(16, 0), table.create(8, 0)
		local tl = 0
		if haveTop then
			for x = 0, 7 do
				top[x + 1] = readu8(Yp, o - ys + x)
			end
			for x = 8, 15 do
				top[x + 1] = haveTR and readu8(Yp, o - ys + x) or top[8]
			end
		end
		if haveLeft then
			for y = 0, 7 do
				left[y + 1] = readu8(Yp, o + y * ys - 1)
			end
		end
		if haveTL then
			tl = readu8(Yp, o - ys - 1)
		end
		if haveTop then
			if haveTL then
				PT[2] = (tl + 2 * top[1] + top[2] + 2) // 4
			else
				PT[2] = (3 * top[1] + top[2] + 2) // 4
			end
			for x = 1, 14 do
				PT[x + 2] = (top[x] + 2 * top[x + 1] + top[x + 2] + 2) // 4
			end
			PT[17] = (top[15] + 3 * top[16] + 2) // 4
		end
		if haveTL then
			local v
			if not haveTop and haveLeft then
				v = (3 * tl + left[1] + 2) // 4
			elseif haveTop and not haveLeft then
				v = (3 * tl + top[1] + 2) // 4
			elseif haveTop and haveLeft then
				v = (top[1] + 2 * tl + left[1] + 2) // 4
			else
				v = tl
			end
			PT[1], PL[1] = v, v
		end
		if haveLeft then
			if haveTL then
				PL[2] = (tl + 2 * left[1] + left[2] + 2) // 4
			else
				PL[2] = (3 * left[1] + left[2] + 2) // 4
			end
			for y = 1, 6 do
				PL[y + 2] = (left[y] + 2 * left[y + 1] + left[y + 2] + 2) // 4
			end
			PL[9] = (left[7] + 3 * left[8] + 2) // 4
		end
		predDirectional(mode, 8, o, haveTop, haveLeft)
	end

	local function predIntra16(mode)
		local gx, gy = mbx * 4, mby * 4
		local o = yo + mby * 16 * ys + mbx * 16
		local haveTop = intraAvail(gx, gy - 1, ord4, 0)
		local haveLeft = intraAvail(gx - 1, gy, ord4, 0)
		local haveTL = intraAvail(gx - 1, gy - 1, ord4, 0)
		if mode == 0 then
			for y = 0, 15 do
				buffer.copy(Yp, o + y * ys, Yp, o - ys, 16)
			end
		elseif mode == 1 then
			for y = 0, 15 do
				buffer.fill(Yp, o + y * ys, readu8(Yp, o + y * ys - 1), 16)
			end
		elseif mode == 2 then
			local sum, cnt = 0, 0
			if haveTop then
				for x = 0, 15 do
					sum += readu8(Yp, o - ys + x)
				end
				cnt += 16
			end
			if haveLeft then
				for y = 0, 15 do
					sum += readu8(Yp, o + y * ys - 1)
				end
				cnt += 16
			end
			local v = cnt > 0 and (sum + cnt // 2) // cnt or 128
			for y = 0, 15 do
				buffer.fill(Yp, o + y * ys, v, 16)
			end
		else -- plane
			local H, V = 0, 0
			for x = 0, 7 do
				H += (x + 1) * (readu8(Yp, o - ys + 8 + x) - readu8(Yp, o - ys + 6 - x))
				V += (x + 1) * (readu8(Yp, o + (8 + x) * ys - 1) - readu8(Yp, o + (6 - x) * ys - 1))
			end
			local a = 16 * (readu8(Yp, o + 15 * ys - 1) + readu8(Yp, o - ys + 15))
			local b = (5 * H + 32) // 64
			local c = (5 * V + 32) // 64
			for y = 0, 15 do
				for x = 0, 15 do
					writeu8(Yp, o + y * ys + x, clip255((a + b * (x - 7) + c * (y - 7) + 16) // 32))
				end
			end
		end
		local _ = haveTL
	end

	local function predChroma(mode)
		local gx, gy = mbx * 4, mby * 4
		local haveTop = intraAvail(gx, gy - 1, ord4, 0)
		local haveLeft = intraAvail(gx - 1, gy, ord4, 0)
		for _, P in ipairs({ Up, Vp }) do
			local o = co + mby * 8 * cs + mbx * 8
			if mode == 0 then -- DC per 4x4
				for blk = 0, 3 do
					local xo, yo2 = (blk % 2) * 4, (blk // 2) * 4
					local st, sl = 0, 0
					for k = 0, 3 do
						if haveTop then
							st += readu8(P, o - cs + xo + k)
						end
						if haveLeft then
							sl += readu8(P, o + (yo2 + k) * cs - 1)
						end
					end
					local v
					if (xo == 0 and yo2 == 0) or (xo > 0 and yo2 > 0) then
						if haveTop and haveLeft then
							v = (st + sl + 4) // 8
						elseif haveTop then
							v = (st + 2) // 4
						elseif haveLeft then
							v = (sl + 2) // 4
						else
							v = 128
						end
					elseif xo > 0 then
						if haveTop then
							v = (st + 2) // 4
						elseif haveLeft then
							v = (sl + 2) // 4
						else
							v = 128
						end
					else
						if haveLeft then
							v = (sl + 2) // 4
						elseif haveTop then
							v = (st + 2) // 4
						else
							v = 128
						end
					end
					for y = 0, 3 do
						buffer.fill(P, o + (yo2 + y) * cs + xo, v, 4)
					end
				end
			elseif mode == 1 then
				for y = 0, 7 do
					buffer.fill(P, o + y * cs, readu8(P, o + y * cs - 1), 8)
				end
			elseif mode == 2 then
				for y = 0, 7 do
					buffer.copy(P, o + y * cs, P, o - cs, 8)
				end
			else
				local H, V = 0, 0
				for x = 0, 3 do
					H += (x + 1) * (readu8(P, o - cs + 4 + x) - readu8(P, o - cs + 2 - x))
					V += (x + 1) * (readu8(P, o + (4 + x) * cs - 1) - readu8(P, o + (2 - x) * cs - 1))
				end
				local a = 16 * (readu8(P, o + 7 * cs - 1) + readu8(P, o - cs + 7))
				local b = (34 * H + 32) // 64
				local c = (34 * V + 32) // 64
				for y = 0, 7 do
					for x = 0, 7 do
						writeu8(P, o + y * cs + x, clip255((a + b * (x - 3) + c * (y - 3) + 16) // 32))
					end
				end
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------
	-- inter prediction

	local PY0, PY1 = buffer.create(256), buffer.create(256)
	local PU0, PU1, PV0, PV1 = buffer.create(64), buffer.create(64), buffer.create(64), buffer.create(64)

	-- predict a partition (bx, by, bw, bh in 4x4 blocks) from the motion stored for its first block
	local function predictPart(bx, by, bw, bh)
		local gx, gy = mbx * 4 + bx, mby * 4 + by
		local i = gy * W4 + gx + 1
		local r0, r1 = ref0[i], ref1[i]
		local lx, ly = gx * 4, gy * 4
		local w, hgt = bw * 4, bh * 4
		local cx, cy = lx // 2, ly // 2
		local cw, ch = w // 2, hgt // 2
		local dl = by * 4 * 16 + bx * 4
		local dc = by * 2 * 8 + bx * 2
		for list = 0, 1 do
			local r = list == 0 and r0 or r1
			if r >= 0 then
				local rp = list == 0 and L0[r + 1] or L1[r + 1]
				local mx = list == 0 and mv0x[i] or mv1x[i]
				local my = list == 0 and mv0y[i] or mv1y[i]
				local dY = list == 0 and PY0 or PY1
				lumaMC(rp.Y, rp.yo, rp.ys, W, Hh, lx + (mx // 4), ly + (my // 4), mx % 4, my % 4, w, hgt, dY, dl)
				local cxi, cyi, cxf, cyf = cx + (mx // 8), cy + (my // 8), mx % 8, my % 8
				chromaMC(rp.U, rp.co, rp.cs, W // 2, Hh // 2, cxi, cyi, cxf, cyf, cw, ch, list == 0 and PU0 or PU1, dc)
				chromaMC(rp.V, rp.co, rp.cs, W // 2, Hh // 2, cxi, cyi, cxf, cyf, cw, ch, list == 0 and PV0 or PV1, dc)
			end
		end
		-- combine into the picture
		local yo2 = yo + ly * ys + lx
		local co2 = co + cy * cs + cx
		if r0 >= 0 and r1 >= 0 then
			local w0, w1, o0, o1, lw = nil, nil, 0, 0, 0
			local cw0u, cw1u, co0u, co1u, cw0v, cw1v, co0v, co1v, lwc
			if implicit then
				local c = implicitWeights(r0, r1)
				w0, w1, lw = c[1], c[2], 5
				cw0u, cw1u, cw0v, cw1v, lwc = w0, w1, w0, w1, 5
				co0u, co1u, co0v, co1v = 0, 0, 0, 0
			elseif wtab then
				local e0, e1 = wtab[0][r0], wtab[1][r1]
				w0, w1, o0, o1, lw = e0.lw, e1.lw, e0.lo, e1.lo, logWDl
				cw0u, cw1u, co0u, co1u = e0.cw1, e1.cw1, e0.co1, e1.co1
				cw0v, cw1v, co0v, co1v = e0.cw2, e1.cw2, e0.co2, e1.co2
				lwc = logWDc
			end
			if w0 then
				local rnd, sh, off = lshift(1, lw), lw + 1, (o0 + o1 + 1) // 2
				for y = 0, hgt - 1 do
					for x = 0, w - 1 do
						local s = dl + y * 16 + x
						writeu8(Yp, yo2 + y * ys + x, clip255(((readu8(PY0, s) * w0 + readu8(PY1, s) * w1 + rnd) // lshift(1, sh)) + off))
					end
				end
				local rc, shc = lshift(1, lwc), lshift(1, lwc + 1)
				local offu, offv = (co0u + co1u + 1) // 2, (co0v + co1v + 1) // 2
				for y = 0, ch - 1 do
					for x = 0, cw - 1 do
						local s = dc + y * 8 + x
						writeu8(Up, co2 + y * cs + x, clip255(((readu8(PU0, s) * cw0u + readu8(PU1, s) * cw1u + rc) // shc) + offu))
						writeu8(Vp, co2 + y * cs + x, clip255(((readu8(PV0, s) * cw0v + readu8(PV1, s) * cw1v + rc) // shc) + offv))
					end
				end
			else
				for y = 0, hgt - 1 do
					for x = 0, w - 1 do
						local s = dl + y * 16 + x
						writeu8(Yp, yo2 + y * ys + x, (readu8(PY0, s) + readu8(PY1, s) + 1) // 2)
					end
				end
				for y = 0, ch - 1 do
					for x = 0, cw - 1 do
						local s = dc + y * 8 + x
						writeu8(Up, co2 + y * cs + x, (readu8(PU0, s) + readu8(PU1, s) + 1) // 2)
						writeu8(Vp, co2 + y * cs + x, (readu8(PV0, s) + readu8(PV1, s) + 1) // 2)
					end
				end
			end
		else
			local list = r0 >= 0 and 0 or 1
			local r = r0 >= 0 and r0 or r1
			local sY = list == 0 and PY0 or PY1
			local sU = list == 0 and PU0 or PU1
			local sV = list == 0 and PV0 or PV1
			local e = wtab and wtab[list] and wtab[list][r]
			if e then
				local lw = logWDl
				local function wl(v, wgt, o, l)
					if l >= 1 then
						return clip255(((v * wgt + lshift(1, l - 1)) // lshift(1, l)) + o)
					end
					return clip255(v * wgt + o)
				end
				for y = 0, hgt - 1 do
					for x = 0, w - 1 do
						writeu8(Yp, yo2 + y * ys + x, wl(readu8(sY, dl + y * 16 + x), e.lw, e.lo, lw))
					end
				end
				for y = 0, ch - 1 do
					for x = 0, cw - 1 do
						local s = dc + y * 8 + x
						writeu8(Up, co2 + y * cs + x, wl(readu8(sU, s), e.cw1, e.co1, logWDc))
						writeu8(Vp, co2 + y * cs + x, wl(readu8(sV, s), e.cw2, e.co2, logWDc))
					end
				end
			else
				for y = 0, hgt - 1 do
					buffer.copy(Yp, yo2 + y * ys, sY, dl + y * 16, w)
				end
				for y = 0, ch - 1 do
					buffer.copy(Up, co2 + y * cs, sU, dc + y * 8, cw)
					buffer.copy(Vp, co2 + y * cs, sV, dc + y * 8, cw)
				end
			end
		end
	end

	-- store motion for the 4x4 blocks of a partition
	local function setMotion(bx, by, bw, bh, list, r, mx, my, mdx, mdy)
		local uid = 0
		if r >= 0 then
			uid = (list == 0 and L0[r + 1] or L1[r + 1]).uid
		end
		for y = by, by + bh - 1 do
			for x = bx, bx + bw - 1 do
				local i = (mby * 4 + y) * W4 + mbx * 4 + x + 1
				if list == 0 then
					ref0[i], mv0x[i], mv0y[i], rp0[i] = r, mx, my, uid
					mvd0x[i], mvd0y[i] = abs(mdx), abs(mdy)
				else
					ref1[i], mv1x[i], mv1y[i], rp1[i] = r, mx, my, uid
					mvd1x[i], mvd1y[i] = abs(mdx), abs(mdy)
				end
			end
		end
	end

	-- direct prediction (B_Skip, B_Direct_16x16, B_8x8 direct sub-macroblocks)
	local spatialCache -- per macroblock: { r0, r1, m0x, m0y, m1x, m1y }
	local function colInfo(bx, by)
		local cbx, cby = bx, by
		if direct8x8 then
			cbx = bx < 2 and 0 or 3
			cby = by < 2 and 0 or 3
		end
		if col.intra[mbAddr + 1] then
			return -1, 0, 0, 0
		end
		local i = (mby * 4 + cby) * W4 + mbx * 4 + cbx + 1
		if col.ref0[i] >= 0 then
			return col.ref0[i], col.mv0x[i], col.mv0y[i], col.rp0[i]
		end
		return col.ref1[i], col.mv1x[i], col.mv1y[i], col.rp1[i]
	end
	local function minPositive(a, b)
		if a >= 0 and b >= 0 then
			return min(a, b)
		end
		return max(a, b)
	end
	local function directBlocks(bx0, by0, size)
		-- size: 4x4 blocks per side of the region (4 for the whole MB, 2 for an 8x8)
		if h.directSpatial then
			if not spatialCache then
				local gx, gy = mbx * 4, mby * 4
				local refs = {}
				for list = 0, 1 do
					local _, ra = neighbour(list, gx - 1, gy, false)
					local _, rb = neighbour(list, gx, gy - 1, false)
					local cAv, rc = neighbour(list, gx + 4, gy - 1, false)
					if not cAv then
						_, rc = neighbour(list, gx - 1, gy - 1, false)
					end
					refs[list] = minPositive(ra, minPositive(rb, rc))
				end
				local c = { refs[0], refs[1], 0, 0, 0, 0, false }
				if c[1] < 0 and c[2] < 0 then
					c[1], c[2] = 0, 0
					c[7] = true -- direct zero prediction
				else
					local saveOrd = curOrd
					curOrd = 0
					if c[1] >= 0 then
						c[3], c[4] = mvPred(0, 0, 0, 4, 4, c[1], 0, 0)
					end
					if c[2] >= 0 then
						c[5], c[6] = mvPred(1, 0, 0, 4, 4, c[2], 0, 0)
					end
					curOrd = saveOrd
				end
				spatialCache = c
			end
			local c = spatialCache
			local l1Long = L1[1].isLong
			for y = by0, by0 + size - 1 do
				for x = bx0, bx0 + size - 1 do
					local m0x, m0y, m1x, m1y = c[3], c[4], c[5], c[6]
					if c[7] then
						m0x, m0y, m1x, m1y = 0, 0, 0, 0
					else
						local rcol, cmx, cmy = colInfo(x, y)
						if not l1Long and rcol == 0 and cmx >= -1 and cmx <= 1 and cmy >= -1 and cmy <= 1 then
							if c[1] == 0 then
								m0x, m0y = 0, 0
							end
							if c[2] == 0 then
								m1x, m1y = 0, 0
							end
						end
					end
					setMotion(x, y, 1, 1, 0, c[1], m0x, m0y, 0, 0)
					setMotion(x, y, 1, 1, 1, c[2], m1x, m1y, 0, 0)
				end
			end
		else
			local p1 = L1[1]
			for y = by0, by0 + size - 1 do
				for x = bx0, bx0 + size - 1 do
					local rcol, cmx, cmy, cuid = colInfo(x, y)
					local r0 = 0
					if rcol >= 0 then
						for k = 1, #L0 do
							if L0[k].uid == cuid then
								r0 = k - 1
								break
							end
						end
					end
					local p0 = L0[r0 + 1]
					local m0x, m0y, m1x, m1y
					local tb = max(-128, min(127, h.poc - p0.poc))
					local td = max(-128, min(127, p1.poc - p0.poc))
					if p0.isLong or td == 0 then
						m0x, m0y, m1x, m1y = cmx, cmy, 0, 0
					else
						local tdh = td >= 0 and td // 2 or -((-td) // 2)
						local num = 16384 + abs(tdh)
						local tx = num // abs(td)
						if td < 0 then
							tx = -tx
						end
						local dsf = max(-1024, min(1023, (tb * tx + 32) // 64))
						m0x = (dsf * cmx + 128) // 256
						m0y = (dsf * cmy + 128) // 256
						m1x, m1y = m0x - cmx, m0y - cmy
					end
					setMotion(x, y, 1, 1, 0, r0, m0x, m0y, 0, 0)
					setMotion(x, y, 1, 1, 1, 0, m1x, m1y, 0, 0)
				end
			end
		end
		for y = by0, by0 + size - 1 do
			for x = bx0, bx0 + size - 1 do
				isDirect[(mby * 4 + y) * W4 + mbx * 4 + x + 1] = true
			end
		end
	end
	-- prediction for direct regions: one call per block group that shares motion
	local function predictDirect(bx0, by0, size)
		if direct8x8 then
			for y = by0, by0 + size - 1, 2 do
				for x = bx0, bx0 + size - 1, 2 do
					predictPart(x, y, 2, 2)
				end
			end
		else
			for y = by0, by0 + size - 1 do
				for x = bx0, bx0 + size - 1 do
					predictPart(x, y, 1, 1)
				end
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------
	-- residual

	local CL = table.create(256, 0) -- luma: 4x4 blocks (blkIdx * 16 + raster) or 8x8 blocks (b8 * 64 + raster)
	local CU = table.create(64, 0) -- chroma blocks (blk * 16 + raster), DC at raster 0
	local CVv = table.create(64, 0)
	local SC = table.create(64, 0) -- levels in scan order, SC[scanIdx + 1]
	local DCT = table.create(16, 0)

	local function clearSC(n)
		for k = 1, n do
			SC[k] = 0
		end
	end
	local function deq4(level, ls, qpv)
		local q6 = qpv // 6
		if qpv >= 24 then
			return level * ls * lshift(1, q6 - 4)
		end
		return (level * ls + lshift(1, 3 - q6)) // lshift(1, 4 - q6)
	end

	-- luma 4x4 block (cat 1 = I16 AC from scan 1, cat 2 = full)
	local function lumaBlock4(blk, cat, lsT, qpv)
		local gx, gy = mbx * 4 + BLK_X[blk + 1], mby * 4 + BLK_Y[blk + 1]
		local startIdx = cat == 1 and 1 or 0
		clearSC(16)
		local n
		if cabac then
			local ctx = 85 + CBF_OFF[cat] + cbfLumaTerm(gx - 1, gy) + 2 * cbfLumaTerm(gx, gy - 1)
			if decodeBin(ctx) == 0 then
				n = 0
			else
				n = cabacResidual(cat, 16 - startIdx, SC, 1, startIdx)
			end
		else
			n = cavlcResidual(cavlcNC(gx, gy, 0), startIdx, 15, 16 - startIdx, SC, 1)
		end
		nnz[gy * W4 + gx + 1] = n
		if n > 0 then
			for s = startIdx, 15 do
				local lv = SC[s + 1]
				if lv ~= 0 then
					local pos = ZZ4[s + 1]
					CL[blk * 16 + pos + 1] = deq4(lv, lsT[pos + 1], qpv)
				end
			end
		end
		return n
	end

	local function lumaBlock8(b8, intra, qpv)
		local lsT = ls8[intra and 6 or 7][qpv % 6]
		local q6 = qpv // 6
		local base = b8 * 64
		clearSC(64)
		local total = 0
		if cabac then
			total = cabacResidual(5, 64, SC, 1, 0)
			for i4 = 0, 3 do
				local blk = b8 * 4 + i4
				nnz[(mby * 4 + BLK_Y[blk + 1]) * W4 + mbx * 4 + BLK_X[blk + 1] + 1] = total
			end
		else
			local tmp = table.create(16, 0)
			local counts = {}
			for i4 = 0, 3 do
				local blk = b8 * 4 + i4
				local gx, gy = mbx * 4 + BLK_X[blk + 1], mby * 4 + BLK_Y[blk + 1]
				for k = 1, 16 do
					tmp[k] = 0
				end
				local n = cavlcResidual(cavlcNC(gx, gy, 0), 0, 15, 16, tmp, 1)
				nnz[gy * W4 + gx + 1] = n
				counts[i4] = n
				total += n
				for k = 0, 15 do
					SC[4 * k + i4 + 1] = tmp[k + 1]
				end
			end
			-- like libavcodec: the first 4x4 of the 8x8 carries the sum (used by the neighbours' nC)
			local blk0 = b8 * 4
			nnz[(mby * 4 + BLK_Y[blk0 + 1]) * W4 + mbx * 4 + BLK_X[blk0 + 1] + 1] = counts[0] + counts[1] + counts[2] + counts[3]
		end
		if total > 0 then
			for s = 0, 63 do
				local lv = SC[s + 1]
				if lv ~= 0 then
					local pos = ZZ8[s + 1]
					local ls = lsT[pos + 1]
					local v
					if qpv >= 36 then
						v = lv * ls * lshift(1, q6 - 6)
					else
						v = (lv * ls + lshift(1, 5 - q6)) // lshift(1, 6 - q6)
					end
					CL[base + pos + 1] = v
				end
			end
		end
		return total
	end

	local function parseResidual(intra, isI16, qpv)
		local qpu = CHROMA_QP[max(0, min(51, qpv + qpOff1)) + 1]
		local qpv2 = CHROMA_QP[max(0, min(51, qpv + qpOff2)) + 1]
		local lsY = ls4[intra and 0 or 3][qpv % 6]
		-- luma
		if isI16 then
			clearSC(16)
			local n
			if cabac then
				local ctx = 85 + cbfDcTerm(mbLeft(), 1) + 2 * cbfDcTerm(mbTop(), 1)
				if decodeBin(ctx) == 0 then
					n = 0
				else
					n = cabacResidual(0, 16, SC, 1, 0)
				end
			else
				n = cavlcResidual(cavlcNC(mbx * 4, mby * 4, 0), 0, 15, 16, SC, 1)
			end
			if n > 0 then
				mbDcCbf[mbAddr + 1] = bor(mbDcCbf[mbAddr + 1], 1)
				for s = 0, 15 do
					DCT[ZZ4[s + 1] + 1] = SC[s + 1]
				end
				-- inverse Hadamard, then scale
				local tmp = table.create(16, 0)
				for i = 0, 3 do
					local c0, c1, c2, c3 = DCT[i * 4 + 1], DCT[i * 4 + 2], DCT[i * 4 + 3], DCT[i * 4 + 4]
					tmp[i * 4 + 1] = c0 + c1 + c2 + c3
					tmp[i * 4 + 2] = c0 + c1 - c2 - c3
					tmp[i * 4 + 3] = c0 - c1 - c2 + c3
					tmp[i * 4 + 4] = c0 - c1 + c2 - c3
				end
				local ls0 = lsY[1]
				local q6 = qpv // 6
				for j = 0, 3 do
					local f0, f1, f2, f3 = tmp[j + 1], tmp[j + 5], tmp[j + 9], tmp[j + 13]
					local col4 = { f0 + f1 + f2 + f3, f0 + f1 - f2 - f3, f0 - f1 - f2 + f3, f0 - f1 + f2 - f3 }
					for i = 0, 3 do
						local f = col4[i + 1]
						local v
						if qpv >= 36 then
							v = f * ls0 * lshift(1, q6 - 6)
						else
							v = (f * ls0 + lshift(1, 5 - q6)) // lshift(1, 6 - q6)
						end
						-- DC matrix element (row i, column j) belongs to the block at x = j, y = i
						CL[BLK_AT[j + 4 * i] * 16 + 1] = v
					end
				end
			end
			for blk = 0, 15 do
				if band(cbpL, 1) ~= 0 then
					lumaBlock4(blk, 1, lsY, qpv)
				else
					nnz[(mby * 4 + BLK_Y[blk + 1]) * W4 + mbx * 4 + BLK_X[blk + 1] + 1] = 0
				end
			end
		else
			for b8 = 0, 3 do
				if band(cbpL, lshift(1, b8)) ~= 0 then
					if t8 then
						lumaBlock8(b8, intra, qpv)
					else
						for i4 = 0, 3 do
							lumaBlock4(b8 * 4 + i4, 2, lsY, qpv)
						end
					end
				else
					for i4 = 0, 3 do
						local blk = b8 * 4 + i4
						nnz[(mby * 4 + BLK_Y[blk + 1]) * W4 + mbx * 4 + BLK_X[blk + 1] + 1] = 0
					end
				end
			end
		end
		-- deblocking: which 4x4 luma blocks have coefficients
		for blk = 0, 15 do
			local i = (mby * 4 + BLK_Y[blk + 1]) * W4 + mbx * 4 + BLK_X[blk + 1] + 1
			coef[i] = nnz[i] > 0
		end
		if t8 then
			for b8 = 0, 3 do
				local any = false
				for k = 1, 64 do
					if CL[b8 * 64 + k] ~= 0 then
						any = true
						break
					end
				end
				for i4 = 0, 3 do
					local blk = b8 * 4 + i4
					coef[(mby * 4 + BLK_Y[blk + 1]) * W4 + mbx * 4 + BLK_X[blk + 1] + 1] = any
				end
			end
		end
		-- chroma
		for k = 0, 3 do
			local ci = (mby * 2 + k // 2) * W2 + mbx * 2 + k % 2 + 1
			nnzU[ci], nnzV[ci] = 0, 0
		end
		if cbpC ~= 0 then
			for plane = 1, 2 do
				local qpc = plane == 1 and qpu or qpv2
				local lsC = ls4[(intra and 0 or 3) + plane][qpc % 6]
				local C = plane == 1 and CU or CVv
				local n
				clearSC(4)
				if cabac then
					local bit = plane == 1 and 2 or 4
					local ctx = 85 + 12 + cbfDcTerm(mbLeft(), bit) + 2 * cbfDcTerm(mbTop(), bit)
					if decodeBin(ctx) == 0 then
						n = 0
					else
						n = cabacResidual(3, 4, SC, 1, 0)
					end
				else
					n = cavlcResidual(-1, 0, 3, 4, SC, 1)
				end
				if n > 0 then
					mbDcCbf[mbAddr + 1] = bor(mbDcCbf[mbAddr + 1], plane == 1 and 2 or 4)
					local c0, c1, c2, c3 = SC[1], SC[2], SC[3], SC[4]
					local f = { c0 + c1 + c2 + c3, c0 - c1 + c2 - c3, c0 + c1 - c2 - c3, c0 - c1 - c2 + c3 }
					local ls0 = lsC[1]
					local q6 = qpc // 6
					for k = 0, 3 do
						C[k * 16 + 1] = (f[k + 1] * ls0 * lshift(1, q6)) // 32
					end
				end
			end
		end
		if cbpC == 2 then
			for plane = 1, 2 do
				local qpc = plane == 1 and qpu or qpv2
				local lsC = ls4[(intra and 0 or 3) + plane][qpc % 6]
				local C = plane == 1 and CU or CVv
				local grid = plane == 1 and nnzU or nnzV
				for k = 0, 3 do
					local cx, cy = mbx * 2 + k % 2, mby * 2 + k // 2
					clearSC(16)
					local n
					if cabac then
						local ctx = 85 + 16 + cbfChromaTerm(plane, cx - 1, cy) + 2 * cbfChromaTerm(plane, cx, cy - 1)
						if decodeBin(ctx) == 0 then
							n = 0
						else
							n = cabacResidual(4, 15, SC, 1, 1)
						end
					else
						n = cavlcResidual(cavlcNC(cx, cy, plane), 1, 15, 15, SC, 1)
					end
					grid[cy * W2 + cx + 1] = n
					if n > 0 then
						for s = 1, 15 do
							local lv = SC[s + 1]
							if lv ~= 0 then
								local pos = ZZ4[s + 1]
								C[k * 16 + pos + 1] = deq4(lv, lsC[pos + 1], qpc)
							end
						end
					end
				end
			end
		end
	end

	-- add the residual of the whole macroblock (luma blocks not done by intra NxN, and chroma)
	local function addLuma4(blk)
		local o = yo + (mby * 16 + BLK_Y[blk + 1] * 4) * ys + mbx * 16 + BLK_X[blk + 1] * 4
		local base = blk * 16
		local acNZ = false
		for k = base + 2, base + 16 do
			if CL[k] ~= 0 then
				acNZ = true
				break
			end
		end
		if acNZ then
			idct4Add(CL, base, Yp, o, ys)
		elseif CL[base + 1] ~= 0 then
			dcAdd4(CL[base + 1], Yp, o, ys)
		end
	end
	local function addLuma8(b8)
		local o = yo + (mby * 16 + (b8 // 2) * 8) * ys + mbx * 16 + (b8 % 2) * 8
		local base = b8 * 64
		for k = base + 1, base + 64 do
			if CL[k] ~= 0 then
				idct8Add(CL, base, Yp, o, ys)
				return
			end
		end
	end
	local function addChroma()
		for plane = 1, 2 do
			local C = plane == 1 and CU or CVv
			local P = plane == 1 and Up or Vp
			for k = 0, 3 do
				local o = co + (mby * 8 + (k // 2) * 4) * cs + mbx * 8 + (k % 2) * 4
				local base = k * 16
				local acNZ = false
				for j = base + 2, base + 16 do
					if C[j] ~= 0 then
						acNZ = true
						break
					end
				end
				if acNZ then
					idct4Add(C, base, P, o, cs)
				elseif C[base + 1] ~= 0 then
					dcAdd4(C[base + 1], P, o, cs)
				end
			end
		end
	end

	------------------------------------------------------------------------------------------------------------------
	-- macroblocks

	local imodes = table.create(16, 0)

	local function clearCoeffs()
		for k = 1, 256 do
			CL[k] = 0
		end
		for k = 1, 64 do
			CU[k] = 0
			CVv[k] = 0
		end
	end
	local function setOrd(bx, by, bw, bh, o)
		for y = by, by + bh - 1 do
			for x = bx, bx + bw - 1 do
				partOrd[y * 4 + x + 1] = o
			end
		end
	end

	local function beginMb(kind)
		mbSlice[mbAddr + 1] = sliceNum
		mbKind[mbAddr + 1] = kind
		D.dbIdc[mbAddr + 1], D.dbA[mbAddr + 1], D.dbB[mbAddr + 1] = dbIdc, dbA, dbB
		D.dbQpOff[mbAddr + 1], D.dbQpOff2[mbAddr + 1] = qpOff1, qpOff2
		mbDcCbf[mbAddr + 1] = 0
		mbT8[mbAddr + 1] = false
		mbChroma[mbAddr + 1] = 0
		curIntra = kind <= K_PCM
		picIntra[mbAddr + 1] = curIntra
		spatialCache = nil
		for y = 0, 3 do
			for x = 0, 3 do
				local i = (mby * 4 + y) * W4 + mbx * 4 + x + 1
				isDirect[i] = false
				mvd0x[i], mvd0y[i], mvd1x[i], mvd1y[i] = 0, 0, 0, 0
				if curIntra then
					ref0[i], ref1[i] = -1, -1
					mv0x[i], mv0y[i], mv1x[i], mv1y[i] = 0, 0, 0, 0
				end
			end
		end
	end

	local function skipMb()
		beginMb(isB and K_BSKIP or K_PSKIP)
		mbQp[mbAddr + 1] = qp
		mbCbp[mbAddr + 1] = 0
		prevQpDeltaNZ = false
		for y = 0, 3 do
			for x = 0, 3 do
				local i = (mby * 4 + y) * W4 + mbx * 4 + x + 1
				nnz[i] = 0
				coef[i] = false
			end
		end
		for k = 0, 3 do
			local ci = (mby * 2 + k // 2) * W2 + mbx * 2 + k % 2 + 1
			nnzU[ci], nnzV[ci] = 0, 0
		end
		setOrd(0, 0, 4, 4, 0)
		curOrd = 0
		if isB then
			directBlocks(0, 0, 4)
			predictDirect(0, 0, 4)
		else
			local gx, gy = mbx * 4, mby * 4
			local aAv, ra, ax, ay = neighbour(0, gx - 1, gy, false)
			local bAv, rb, bx2, by2 = neighbour(0, gx, gy - 1, false)
			local mx, my = 0, 0
			if aAv and bAv and not (ra == 0 and ax == 0 and ay == 0) and not (rb == 0 and bx2 == 0 and by2 == 0) then
				mx, my = mvPred(0, 0, 0, 4, 4, 0, 0, 0)
			end
			setMotion(0, 0, 4, 4, 0, 0, mx, my, 0, 0)
			setMotion(0, 0, 4, 4, 1, -1, 0, 0, 0, 0)
			predictPart(0, 0, 4, 4)
		end
	end

	local function pcmMb()
		local pos
		if cabac then
			pos = (cabacBitPos() + 7) // 8
		else
			pos = (BP + 7) // 8
		end
		local o = yo + mby * 16 * ys + mbx * 16
		for y = 0, 15 do
			for x = 0, 15 do
				writeu8(Yp, o + y * ys + x, readu8(RB, pos))
				pos += 1
			end
		end
		for _, P in ipairs({ Up, Vp }) do
			local oc = co + mby * 8 * cs + mbx * 8
			for y = 0, 7 do
				for x = 0, 7 do
					writeu8(P, oc + y * cs + x, readu8(RB, pos))
					pos += 1
				end
			end
		end
		if cabac then
			cabacStart(pos)
		else
			BP = pos * 8
		end
		mbQp[mbAddr + 1] = 0 -- for the filter; the qp prediction keeps going from the last one
		mbCbp[mbAddr + 1] = 15 + 32
		prevQpDeltaNZ = false
		for y = 0, 3 do
			for x = 0, 3 do
				local i = (mby * 4 + y) * W4 + mbx * 4 + x + 1
				nnz[i] = 16
				coef[i] = true
			end
		end
		for k = 0, 3 do
			local ci = (mby * 2 + k // 2) * W2 + mbx * 2 + k % 2 + 1
			nnzU[ci], nnzV[ci] = 16, 16
		end
		mbDcCbf[mbAddr + 1] = 7
	end

	local function decodeMb()
		local mt = readMbType()
		local intraType -- 0 = I_NxN, 1..24 = I16, 25 = PCM
		if isI then
			intraType = mt
		elseif not isB then
			if mt >= 5 then
				intraType = mt - 5
			end
		else
			if mt >= 23 then
				intraType = mt - 23
			end
		end
		if intraType and intraType > 25 then
			fail("broken data (bad macroblock type)")
		end
		if intraType == 25 then
			beginMb(K_PCM)
			pcmMb()
			return
		end
		cbpL, cbpC = 0, 0
		t8 = false
		clearCoeffs()
		if intraType then
			local isI16 = intraType > 0
			local predMode16
			if isI16 then
				local k = intraType - 1
				predMode16 = k % 4
				cbpC = (k // 4) % 3
				cbpL = k >= 12 and 15 or 0
				beginMb(K_I16)
			else
				beginMb(K_I4)
				if t8mode then
					t8 = readT8Flag()
					if t8 then
						mbKind[mbAddr + 1] = K_I8
						mbT8[mbAddr + 1] = true
					end
				end
				-- prediction modes
				if t8 then
					for b8 = 0, 3 do
						local bx, by = (b8 % 2) * 2, (b8 // 2) * 2
						local gx, gy = mbx * 4 + bx, mby * 4 + by
						local pred = predictedIntraMode(gx, gy)
						local m
						if readPrevIntraFlag() then
							m = pred
						else
							local rem = readRemIntra()
							m = rem < pred and rem or rem + 1
						end
						for y = 0, 1 do
							for x = 0, 1 do
								imode[(gy + y) * W4 + gx + x + 1] = m
							end
						end
						imodes[b8 + 1] = m
					end
				else
					for blk = 0, 15 do
						local gx, gy = mbx * 4 + BLK_X[blk + 1], mby * 4 + BLK_Y[blk + 1]
						local pred = predictedIntraMode(gx, gy)
						local m
						if readPrevIntraFlag() then
							m = pred
						else
							local rem = readRemIntra()
							m = rem < pred and rem or rem + 1
						end
						imode[gy * W4 + gx + 1] = m
						imodes[blk + 1] = m
					end
				end
			end
			if not (mbKind[mbAddr + 1] == K_I4 or mbKind[mbAddr + 1] == K_I8) then
				for y = 0, 3 do
					for x = 0, 3 do
						imode[(mby * 4 + y) * W4 + mbx * 4 + x + 1] = 2
					end
				end
			end
			local cm = readChromaMode()
			mbChroma[mbAddr + 1] = cm
			if not isI16 then
				local cbp = readCbp(true)
				cbpL, cbpC = cbp % 16, cbp // 16
			end
			mbCbp[mbAddr + 1] = cbpL + 16 * cbpC
			local qpd = 0
			if cbpL > 0 or cbpC > 0 or isI16 then
				qpd = readQpDelta()
				qp = (qp + qpd + 52) % 52
			end
			prevQpDeltaNZ = qpd ~= 0
			mbQp[mbAddr + 1] = qp
			if cbpL > 0 or cbpC > 0 or isI16 then
				parseResidual(true, isI16, qp)
			else
				parseResidual(true, false, qp)
			end
			-- reconstruct
			if isI16 then
				predIntra16(predMode16)
				for blk = 0, 15 do
					addLuma4(blk)
				end
			elseif t8 then
				for b8 = 0, 3 do
					predIntra8(b8, imodes[b8 + 1])
					addLuma8(b8)
				end
			else
				for blk = 0, 15 do
					predIntra4(blk, imodes[blk + 1])
					addLuma4(blk)
				end
			end
			predChroma(cm)
			addChroma()
			return
		end

		-- inter
		local kind = K_P
		if isB then
			kind = mt == 0 and K_BDIRECT or K_B
		end
		beginMb(kind)
		for y = 0, 3 do
			for x = 0, 3 do
				imode[(mby * 4 + y) * W4 + mbx * 4 + x + 1] = 2
			end
		end
		local noSmall = true -- no sub-macroblock partition smaller than 8x8
		local parts = {} -- { bx, by, bw, bh, ord, pred (bit 1 L0, bit 2 L1), shape, partIdx, direct }
		if isB and mt == 0 then
			setOrd(0, 0, 4, 4, 0)
			curOrd = 0
			directBlocks(0, 0, 4)
			table.insert(parts, { 0, 0, 4, 4, 0, 0, 0, 0, true })
			if not direct8x8 then
				noSmall = false
			end
		elseif (not isB and mt <= 2) or (isB and mt <= 21) then
			local shape, p0, p1
			if isB then
				local t = B_TYPES[mt]
				shape, p0, p1 = t[1], t[2], t[3]
			else
				shape, p0, p1 = mt, 1, 1
			end
			if shape == 0 then
				table.insert(parts, { 0, 0, 4, 4, 0, p0, 0, 0 })
			elseif shape == 1 then
				table.insert(parts, { 0, 0, 4, 2, 0, p0, 1, 0 })
				table.insert(parts, { 0, 2, 4, 2, 1, p1, 1, 1 })
			else
				table.insert(parts, { 0, 0, 2, 4, 0, p0, 2, 0 })
				table.insert(parts, { 2, 0, 2, 4, 1, p1, 2, 1 })
			end
			for _, p in ipairs(parts) do
				setOrd(p[1], p[2], p[3], p[4], p[5])
			end
		else
			-- 8x8 sub-macroblocks
			local subs = {}
			for s = 0, 3 do
				subs[s] = readSubType()
				if (isB and subs[s] > 12) or (not isB and subs[s] > 3) then
					fail("broken data (bad sub-macroblock type)")
				end
			end
			for s = 0, 3 do
				local info = isB and B_SUB[subs[s]] or P_SUB[subs[s]]
				local bx, by = (s % 2) * 2, (s // 2) * 2
				if info[2] == 0 then
					setOrd(bx, by, 2, 2, s * 4)
					table.insert(parts, { bx, by, 2, 2, s * 4, 0, 0, 0, true })
					if not direct8x8 then
						noSmall = false
					end
				else
					local shape = info[1]
					if shape ~= 0 then
						noSmall = false
					end
					local pw, ph = (shape == 0 or shape == 1) and 2 or 1, (shape == 0 or shape == 2) and 2 or 1
					local k = 0
					for py = 0, 2 - ph, ph do
						for px = 0, 2 - pw, pw do
							setOrd(bx + px, by + py, pw, ph, s * 4 + k)
							table.insert(parts, { bx + px, by + py, pw, ph, s * 4 + k, info[2], 0, 0, false, s })
							k += 1
						end
					end
				end
			end
			-- direct sub-macroblocks first (others may predict from them)
			for _, p in ipairs(parts) do
				if p[9] then
					curOrd = p[5]
					directBlocks(p[1], p[2], 2)
				end
			end
		end
		-- reference indices: all of list 0, then list 1 (one per partition, or per 8x8 sub-macroblock)
		local isRef0 = (not isB) and mt == 4
		local seen = {}
		for list = 0, 1 do
			local numRef = list == 0 and numRef0 or numRef1
			for _, p in ipairs(parts) do
				if not p[9] then
					local key = p[10] and ("s" .. p[10]) or p[5]
					local r = -1
					if band(p[6], list + 1) ~= 0 then
						if seen[list .. key] then
							r = seen[list .. key]
						else
							curOrd = p[5]
							r = isRef0 and 0 or readRefIdx(list, mbx * 4 + p[1], mby * 4 + p[2], numRef)
							if r >= numRef then
								fail("broken data (reference index out of range)")
							end
							seen[list .. key] = r
						end
					end
					for y = p[2], p[2] + p[4] - 1 do
						for x = p[1], p[1] + p[3] - 1 do
							local i = (mby * 4 + y) * W4 + mbx * 4 + x + 1
							if list == 0 then
								ref0[i] = r
							else
								ref1[i] = r
							end
						end
					end
					p[10 + list + 1] = r
				end
			end
		end
		-- motion vectors: all of list 0, then list 1
		for list = 0, 1 do
			for _, p in ipairs(parts) do
				if not p[9] then
					local r = p[11 + list]
					curOrd = p[5]
					if r >= 0 then
						local gx, gy = mbx * 4 + p[1], mby * 4 + p[2]
						local dx = readMvd(list, 0, gx, gy)
						local dy = readMvd(list, 1, gx, gy)
						local px, py = mvPred(list, p[1], p[2], p[3], p[4], r, p[7], p[8])
						setMotion(p[1], p[2], p[3], p[4], list, r, px + dx, py + dy, dx, dy)
					else
						setMotion(p[1], p[2], p[3], p[4], list, -1, 0, 0, 0, 0)
					end
				end
			end
		end
		-- residual syntax
		local cbp = readCbp(false)
		cbpL, cbpC = cbp % 16, cbp // 16
		mbCbp[mbAddr + 1] = cbpL + 16 * cbpC
		if cbpL > 0 and t8mode and noSmall then
			t8 = readT8Flag()
			mbT8[mbAddr + 1] = t8
		end
		local qpd = 0
		if cbpL > 0 or cbpC > 0 then
			qpd = readQpDelta()
			qp = (qp + qpd + 52) % 52
		end
		prevQpDeltaNZ = qpd ~= 0
		mbQp[mbAddr + 1] = qp
		parseResidual(false, false, qp)
		-- prediction, then the residual
		for _, p in ipairs(parts) do
			if p[9] then
				predictDirect(p[1], p[2], p[3])
			else
				predictPart(p[1], p[2], p[3], p[4])
			end
		end
		if t8 then
			for b8 = 0, 3 do
				addLuma8(b8)
			end
		else
			for blk = 0, 15 do
				addLuma4(blk)
			end
		end
		addChroma()
	end

	------------------------------------------------------------------------------------------------------------------
	-- the slice's macroblocks

	if cabac then
		cabacInitContexts(h.qp, h.cabacInit or 0, isI)
		cabacStart((BP + 7) // 8)
	end
	mbAddr = h.firstMb
	local total = mbw * mbh
	if mbAddr >= total then
		fail("broken data (slice starts outside the picture)")
	end
	local skipRun = -1
	local rows = 0
	while true do
		mbx, mby = mbAddr % mbw, mbAddr // mbw
		local skipped = false
		if not isI then
			if cabac then
				skipped = cabacSkipFlag()
			else
				if skipRun < 0 then
					skipRun = ue()
				end
				if skipRun > 0 then
					skipped = true
					skipRun -= 1
				else
					skipRun = -1 -- a coded macroblock; a new run follows it
				end
			end
		end
		if skipped then
			skipMb()
		else
			decodeMb()
		end
		if mbx == mbw - 1 then
			rows += 1
			breathe()
		end
		-- next macroblock?
		local more
		if cabac then
			more = decodeTerminate() == 0
		else
			if skipped and skipRun > 0 then
				more = true
			else
				-- after a run (skipRun 0: a coded macroblock comes next, without another run) or a coded macroblock
				more = moreRbspData()
			end
		end
		mbAddr += 1
		if not more then
			break
		end
		if mbAddr >= total then
			break
		end
	end
	return mbAddr
end

------------------------------------------------------------------------------------------------------------------------
-- deblocking filter (8.7), macroblock by macroblock once the picture is decoded

local function deblockPicture(D, pic)
	local mbw, mbh = D.mbw, D.mbh
	local W4, W2 = D.W4, D.W2
	local Yp, Up, Vp, ys, cs, yo, co = pic.Y, pic.U, pic.V, pic.ys, pic.cs, pic.yo, pic.co
	local mbSlice, mbQp, mbT8 = D.mbSlice, D.mbQp, D.mbT8
	local coef = D.coef
	local intra = pic.intra
	local ref0, ref1, rp0, rp1 = pic.ref0, pic.ref1, pic.rp0, pic.rp1
	local mv0x, mv0y, mv1x, mv1y = pic.mv0x, pic.mv0y, pic.mv1x, pic.mv1y
	local bS = table.create(4, 0)

	local function mvFar(ax, ay, bx, by)
		return abs(ax - bx) >= 4 or abs(ay - by) >= 4
	end
	local function strength(pi, qi, pmb, qmb, mbEdge)
		if intra[pmb + 1] or intra[qmb + 1] then
			return mbEdge and 4 or 3
		end
		if coef[pi] or coef[qi] then
			return 2
		end
		local pa = ref0[pi] >= 0 and rp0[pi] or nil
		local pb = ref1[pi] >= 0 and rp1[pi] or nil
		local qa = ref0[qi] >= 0 and rp0[qi] or nil
		local qb = ref1[qi] >= 0 and rp1[qi] or nil
		local np = (pa and 1 or 0) + (pb and 1 or 0)
		local nq = (qa and 1 or 0) + (qb and 1 or 0)
		if np ~= nq then
			return 1
		end
		if np == 1 then
			local pr = pa or pb
			local qr = qa or qb
			if pr ~= qr then
				return 1
			end
			local pmx, pmy = pa and mv0x[pi] or mv1x[pi], pa and mv0y[pi] or mv1y[pi]
			local qmx, qmy = qa and mv0x[qi] or mv1x[qi], qa and mv0y[qi] or mv1y[qi]
			return mvFar(pmx, pmy, qmx, qmy) and 1 or 0
		end
		if np == 0 then
			return 0
		end
		-- two motion vectors each
		if not ((pa == qa and pb == qb) or (pa == qb and pb == qa)) then
			return 1
		end
		if pa ~= pb then
			if pa == qa then
				return (mvFar(mv0x[pi], mv0y[pi], mv0x[qi], mv0y[qi]) or mvFar(mv1x[pi], mv1y[pi], mv1x[qi], mv1y[qi])) and 1 or 0
			end
			return (mvFar(mv0x[pi], mv0y[pi], mv1x[qi], mv1y[qi]) or mvFar(mv1x[pi], mv1y[pi], mv0x[qi], mv0y[qi])) and 1 or 0
		end
		local straight = mvFar(mv0x[pi], mv0y[pi], mv0x[qi], mv0y[qi]) or mvFar(mv1x[pi], mv1y[pi], mv1x[qi], mv1y[qi])
		local crossed = mvFar(mv0x[pi], mv0y[pi], mv1x[qi], mv1y[qi]) or mvFar(mv1x[pi], mv1y[pi], mv0x[qi], mv0y[qi])
		return (straight and crossed) and 1 or 0
	end

	-- filter `n` lines across an edge: sample q0 of line k at o + k * along, p side at -step
	local function filterLuma(P, o, step, along, n, bsv, alpha, beta, indexA)
		for k = 0, n - 1 do
			local s = bsv[k // 4 + 1]
			if s > 0 then
				local q = o + k * along
				local p0, q0 = readu8(P, q - step), readu8(P, q)
				local p1, q1 = readu8(P, q - 2 * step), readu8(P, q + step)
				if abs(p0 - q0) < alpha and abs(p1 - p0) < beta and abs(q1 - q0) < beta then
					local p2, q2 = readu8(P, q - 3 * step), readu8(P, q + 2 * step)
					local ap, aq = abs(p2 - p0), abs(q2 - q0)
					if s < 4 then
						local tc0 = TC0[indexA * 4 + s + 1]
						local tc = tc0 + (ap < beta and 1 or 0) + (aq < beta and 1 or 0)
						local delta = (((q0 - p0) * 4) + (p1 - q1) + 4) // 8
						delta = delta < -tc and -tc or (delta > tc and tc or delta)
						writeu8(P, q - step, clip255(p0 + delta))
						writeu8(P, q, clip255(q0 - delta))
						if ap < beta then
							local d = (p2 + ((p0 + q0 + 1) // 2) - p1 * 2) // 2
							d = d < -tc0 and -tc0 or (d > tc0 and tc0 or d)
							writeu8(P, q - 2 * step, clip255(p1 + d))
						end
						if aq < beta then
							local d = (q2 + ((p0 + q0 + 1) // 2) - q1 * 2) // 2
							d = d < -tc0 and -tc0 or (d > tc0 and tc0 or d)
							writeu8(P, q + step, clip255(q1 + d))
						end
					else
						local small = abs(p0 - q0) < (alpha // 4) + 2
						if ap < beta and small then
							local p3 = readu8(P, q - 4 * step)
							writeu8(P, q - step, (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) // 8)
							writeu8(P, q - 2 * step, (p2 + p1 + p0 + q0 + 2) // 4)
							writeu8(P, q - 3 * step, (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) // 8)
						else
							writeu8(P, q - step, (2 * p1 + p0 + q1 + 2) // 4)
						end
						if aq < beta and small then
							local q3 = readu8(P, q + 3 * step)
							writeu8(P, q, (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) // 8)
							writeu8(P, q + step, (p0 + q0 + q1 + q2 + 2) // 4)
							writeu8(P, q + 2 * step, (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) // 8)
						else
							writeu8(P, q, (2 * q1 + q0 + p1 + 2) // 4)
						end
					end
				end
			end
		end
	end
	local function filterChroma(P, o, step, along, bsv, alpha, beta, indexA)
		for k = 0, 7 do
			local s = bsv[k // 2 + 1]
			if s > 0 then
				local q = o + k * along
				local p0, q0 = readu8(P, q - step), readu8(P, q)
				local p1, q1 = readu8(P, q - 2 * step), readu8(P, q + step)
				if abs(p0 - q0) < alpha and abs(p1 - p0) < beta and abs(q1 - q0) < beta then
					if s < 4 then
						local tc = TC0[indexA * 4 + s + 1] + 1
						local delta = (((q0 - p0) * 4) + (p1 - q1) + 4) // 8
						delta = delta < -tc and -tc or (delta > tc and tc or delta)
						writeu8(P, q - step, clip255(p0 + delta))
						writeu8(P, q, clip255(q0 - delta))
					else
						writeu8(P, q - step, (2 * p1 + p0 + q1 + 2) // 4)
						writeu8(P, q, (2 * q1 + q0 + p1 + 2) // 4)
					end
				end
			end
		end
	end
	local function chromaQp(qpy, off)
		return CHROMA_QP[max(0, min(51, qpy + off)) + 1]
	end

	for mby = 0, mbh - 1 do
		breathe()
		for mbx = 0, mbw - 1 do
			local mb = mby * mbw + mbx
			local idc = D.dbIdc[mb + 1]
			if idc ~= 1 and mbSlice[mb + 1] ~= -1 then
				local offA, offB = D.dbA[mb + 1], D.dbB[mb + 1]
				local qoff1, qoff2 = D.dbQpOff[mb + 1], D.dbQpOff2[mb + 1]
				local t8 = mbT8[mb + 1]
				local qq = mbQp[mb + 1]
				for dir = 0, 1 do -- 0: vertical edges, 1: horizontal edges
					for e = 0, 3 do
						local doEdge = true
						local pmb = mb
						if e == 0 then
							if dir == 0 then
								doEdge = mbx > 0 and (idc ~= 2 or mbSlice[mb] == mbSlice[mb + 1])
								pmb = mb - 1
							else
								doEdge = mby > 0 and (idc ~= 2 or mbSlice[mb - mbw + 1] == mbSlice[mb + 1])
								pmb = mb - mbw
							end
						elseif t8 and e % 2 == 1 then
							doEdge = false
						end
						if doEdge then
							local any = false
							for k = 0, 3 do
								local gx, gy, px, py
								if dir == 0 then
									gx, gy = mbx * 4 + e, mby * 4 + k
									px, py = gx - 1, gy
								else
									gx, gy = mbx * 4 + k, mby * 4 + e
									px, py = gx, gy - 1
								end
								local s = strength(py * W4 + px + 1, gy * W4 + gx + 1, pmb, mb, e == 0)
								bS[k + 1] = s
								if s > 0 then
									any = true
								end
							end
							if any then
								local qp = mbQp[pmb + 1]
								local qpav = (qp + qq + 1) // 2
								local indexA = max(0, min(51, qpav + offA))
								local indexB = max(0, min(51, qpav + offB))
								local alpha, beta = ALPHA[indexA + 1], BETA[indexB + 1]
								local o, step, along
								if dir == 0 then
									o = yo + mby * 16 * ys + mbx * 16 + e * 4
									step, along = 1, ys
								else
									o = yo + (mby * 16 + e * 4) * ys + mbx * 16
									step, along = ys, 1
								end
								if alpha > 0 and beta > 0 then
									filterLuma(Yp, o, step, along, 16, bS, alpha, beta, indexA)
								end
								if e % 2 == 0 then
									for plane = 1, 2 do
										local off = plane == 1 and qoff1 or qoff2
										local cqav = (chromaQp(qp, off) + chromaQp(qq, off) + 1) // 2
										local cA = max(0, min(51, cqav + offA))
										local cB = max(0, min(51, cqav + offB))
										local ca, cb = ALPHA[cA + 1], BETA[cB + 1]
										if ca > 0 and cb > 0 then
											local P = plane == 1 and Up or Vp
											local oc
											if dir == 0 then
												oc = co + mby * 8 * cs + mbx * 8 + e * 2
												filterChroma(P, oc, 1, cs, bS, ca, cb, cA)
											else
												oc = co + (mby * 8 + e * 2) * cs + mbx * 8
												filterChroma(P, oc, cs, 1, bS, ca, cb, cA)
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- pictures in, pictures out

local function finishPicture(D)
	local cur = D.cur
	if not cur then
		return nil
	end
	D.cur = nil
	local pic, h = cur.pic, cur.h
	deblockPicture(D, pic)
	padPicture(D, pic)
	if h.refIdc ~= 0 then
		markReference(D, pic, h)
	end
	-- state for the next picture order counts
	if h.mmco5 then
		local temp = min(cur.top, cur.bottom)
		pic.poc = cur.poc - temp
		pic.frameNum = 0
		D.prevPocMsb = 0
		D.prevPocLsb = cur.top - temp
		D.prevFrameNumOffset = 0
		D.prevFrameNum = 0
	else
		if h.refIdc ~= 0 and h.sps.pocType == 0 then
			D.prevPocMsb = h.pocMsb or 0
			D.prevPocLsb = h.pocLsb
		end
		D.prevFrameNumOffset = h.frameNumOffset or 0
		D.prevFrameNum = h.frameNum
	end
	-- pictures nobody needs any more go back to the pool
	local keep = {}
	for _, p in ipairs(D.dpb) do
		keep[p] = true
	end
	for _, p in ipairs(D.live or {}) do
		if not keep[p] and p ~= pic then
			table.insert(D.free, p)
		end
	end
	D.live = table.clone(D.dpb)
	if not keep[pic] then
		table.insert(D.live, pic) -- the output stays valid until the next call
	end
	return pic
end

function Decoder:nal(buf, pos, len)
	if len < 1 then
		return
	end
	local hdr = readu8(buf, pos)
	local nalType = band(hdr, 31)
	local refIdc = band(rshift(hdr, 5), 3)
	if nalType == 7 then
		loadRbsp(buf, pos + 1, len - 1)
		local s = parseSps()
		self.spsList[s.id] = s
	elseif nalType == 8 then
		loadRbsp(buf, pos + 1, len - 1)
		local p = parsePps(self.spsList)
		self.ppsList[p.id] = p
	elseif nalType == 1 or nalType == 5 then
		loadRbsp(buf, pos + 1, len - 1)
		local h = parseSliceHeader(self, nalType, refIdc)
		if h.redundantPicCnt and h.redundantPicCnt > 0 then
			return
		end
		local sps = h.sps
		if self.cur and (h.firstMb == 0 or h.frameNum ~= self.cur.h.frameNum or h.pps ~= self.cur.h.pps and false) then
			if h.firstMb == 0 then
				self.finished = finishPicture(self)
			end
		end
		if not self.cur then
			setupSize(self, sps)
			if h.idr then
				self.seenIdr = true
			elseif not self.seenIdr and h.type ~= 2 then
				return -- before the first key frame: nothing to predict from
			end
			local poc, top, bottom = computePoc(self, h)
			h.poc = poc
			local pic = newPicture(self)
			pic.poc = poc
			pic.frameNum = h.frameNum
			pic.isLong, pic.isRef = false, false
			for i = 1, #pic.intra do
				pic.intra[i] = false
			end
			self.cur = { pic = pic, h = h, poc = poc, top = top, bottom = bottom }
			self.width = sps.mbw * 16 - sps.cropLeft - sps.cropRight
			self.height = sps.mbh * 16 - sps.cropTop - sps.cropBottom
			self.cropX, self.cropY = sps.cropLeft, sps.cropTop
			self.bt709, self.fullRange = sps.bt709, sps.fullRange
		else
			h.poc = self.cur.poc
			-- later slices carry the same marking; keep the first slice's header for the picture
			if h.mmco then
				self.cur.h.mmco = h.mmco
			end
		end
		decodeSlice(self, h, self.cur.pic)
	elseif nalType == 2 or nalType == 3 or nalType == 4 then
		fail("data-partitioned slices aren't supported")
	end
end

-- one access unit (MP4 sample: length-prefixed NAL units); returns the decoded picture or nil
function Decoder:decodeSample(buf, pos, len)
	local stop = pos + len
	local nl = self.nalLength
	self.finished = nil
	while pos + nl <= stop do
		local n = 0
		for k = 0, nl - 1 do
			n = n * 256 + readu8(buf, pos + k)
		end
		pos += nl
		if n > stop - pos then
			n = stop - pos
		end
		self:nal(buf, pos, n)
		pos += n
	end
	local pic = finishPicture(self)
	return pic or self.finished
end

-- Annex B byte stream (00 00 01 start codes), for raw .h264 files; returns the pictures in decoding order
function Decoder:decodeAnnexB(buf, onPicture)
	local len = buffer.len(buf)
	local i = 0
	local starts = {}
	while i + 3 <= len do
		if readu8(buf, i) == 0 and readu8(buf, i + 1) == 0 and readu8(buf, i + 2) == 1 then
			table.insert(starts, i + 3)
			i += 3
		else
			i += 1
		end
	end
	for k, s in ipairs(starts) do
		local e = starts[k + 1] and starts[k + 1] - 3 or len
		while e > s and readu8(buf, e - 1) == 0 do
			e -= 1
		end
		local nalType = band(readu8(buf, s), 31)
		if (nalType == 1 or nalType == 5) and self.cur then
			-- a new picture starts when first_mb_in_slice is 0
			loadRbsp(buf, s + 1, min(e - s - 1, 16))
			if ue() == 0 then
				local pic = finishPicture(self)
				if pic and onPicture then
					onPicture(pic)
				end
			end
		end
		self:nal(buf, s, e - s)
	end
	local pic = finishPicture(self)
	if pic and onPicture then
		onPicture(pic)
	end
end

H264.K = { I4 = K_I4 }
return H264
