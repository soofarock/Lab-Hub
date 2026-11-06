--!native
--!optimize 2
-- AAC decoder (MPEG-4 AAC-LC, ISO/IEC 14496-3; the core of HE-AAC is decoded at its own rate, without SBR / PS).
-- Long and short windows, sine and KBD window shapes, M/S and intensity stereo, noise substitution (PNS), pulses and
-- temporal noise shaping. Output is mixed to stereo (or mono).
--
--   local cfg = Aac.parseConfig(ascBytes)                      -- AudioSpecificConfig (MP4 'esds')
--   local signal = Aac.decodeFrames(cfg, buf, frames, { Yield, MaxSeconds, Skip })   -- frames = { { pos, size } }
--   local dec = Aac.new(cfg); local L, R, stereo = dec:decodeFrame(buf, pos, len)   -- 1024 samples per channel
--   Aac.isAdts(bytes) / Aac.parseAdts(bytes) -> cfg, frames      -- raw .aac files
--   errors start with "AAC: "

-- AAC tables (from the ISO 14496-3 tables, as in FFmpeg aactab.c)
local T = {}
T.sfCodes = {262120,262118,262119,262117,524277,524273,524269,524278,524270,524271,524272,524284,524285,524287,524286,524279,524280,524283,524281,262116,524282,262115,131055,131056,65525,131054,65522,65523,65524,65521,32758,32759,16377,16373,16375,16371,16374,16370,8183,8181,4089,4087,4086,2041,4084,2040,1017,1015,1013,504,503,250,248,246,121,58,56,26,11,4,0,10,12,27,57,59,120,122,247,249,502,505,1012,1014,1016,2037,2036,2038,2039,4085,4088,8180,8182,8184,16376,16372,65520,32756,65526,32757,262114,524249,524250,524251,524252,524253,524254,524248,524242,524243,524244,524245,524246,524274,524255,524263,524264,524265,524266,524267,524262,524256,524257,524258,524259,524260,524261,524247,524268,524276,524275}
T.sfBits = {18,18,18,18,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,18,19,18,17,17,16,17,16,16,16,16,15,15,14,14,14,14,14,14,13,13,12,12,12,11,12,11,10,10,10,9,9,8,8,8,7,6,6,5,4,3,1,4,4,5,6,6,7,7,8,8,9,9,10,10,10,11,11,11,11,12,12,13,13,13,14,14,16,15,16,15,18,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19}
T.spectral = {
{ codes = {2040,497,2045,1013,104,1008,2039,492,2037,1009,114,1012,116,17,118,491,108,1014,2044,481,2033,496,97,502,2034,490,2043,498,105,493,119,23,111,486,100,485,103,21,98,18,0,20,101,22,109,489,99,484,107,19,113,483,112,499,2046,487,2035,495,96,494,2032,482,2042,1011,106,488,117,16,115,500,110,1015,2038,480,2041,1010,102,501,2047,503,2036}, bits = {11,9,11,10,7,10,11,9,11,10,7,10,7,5,7,9,7,10,11,9,11,9,7,9,11,9,11,9,7,9,7,5,7,9,7,9,7,5,7,5,1,5,7,5,7,9,7,9,7,5,7,9,7,9,11,9,11,9,7,9,11,9,11,10,7,9,7,5,7,9,7,10,11,9,11,10,7,9,11,9,11} },
{ codes = {499,111,509,235,35,234,503,232,506,242,45,112,32,6,43,110,40,233,505,102,248,231,27,241,500,107,501,236,42,108,44,10,39,103,26,245,36,8,31,9,0,7,29,11,48,239,28,100,30,12,41,243,47,240,508,113,498,244,33,230,247,104,504,238,34,101,49,2,38,237,37,106,507,114,510,105,46,246,511,109,502}, bits = {9,7,9,8,6,8,9,8,9,8,6,7,6,5,6,7,6,8,9,7,8,8,6,8,9,7,9,8,6,7,6,5,6,7,6,8,6,5,6,5,3,5,6,5,6,8,6,7,6,5,6,8,6,8,9,7,9,8,6,8,8,7,9,8,6,7,6,4,6,8,6,7,9,7,9,7,6,8,9,7,9} },
{ codes = {0,9,239,11,25,240,491,486,1010,10,53,495,52,55,489,493,487,1011,494,1005,8186,492,498,2041,2040,1016,4088,8,56,1014,54,117,1009,1003,1004,4084,24,118,2036,57,116,1007,499,500,2038,488,1002,8188,242,497,4091,1013,2035,4092,238,1015,32766,496,2037,32765,8187,16378,65535,241,1008,16380,490,1006,16379,4086,4090,32764,2034,4085,65534,1012,2039,32763,4087,4089,32762}, bits = {1,4,8,4,5,8,9,9,10,4,6,9,6,6,9,9,9,10,9,10,13,9,9,11,11,10,12,4,6,10,6,7,10,10,10,12,5,7,11,6,7,10,9,9,11,9,10,13,8,9,12,10,11,12,8,10,15,9,11,15,13,14,16,8,10,14,9,10,14,12,12,15,11,12,16,10,11,15,12,12,15} },
{ codes = {7,22,246,24,8,239,495,243,2040,25,23,237,21,1,226,240,112,1008,494,241,2042,238,228,1010,2038,1007,2045,5,20,242,9,4,229,244,232,1012,6,2,231,3,0,107,227,105,499,235,230,1014,110,106,500,1004,496,1017,245,236,2043,234,111,1015,2041,1011,4095,233,109,1016,108,104,501,1006,498,2036,2039,1009,4094,1005,497,2037,2046,1013,2044}, bits = {4,5,8,5,4,8,9,8,11,5,5,8,5,4,8,8,7,10,9,8,11,8,8,10,11,10,11,4,5,8,4,4,8,8,8,10,4,4,8,4,4,7,8,7,9,8,8,10,7,7,9,10,9,10,8,8,11,8,7,10,11,10,12,8,7,10,7,7,9,10,9,11,11,10,12,10,9,11,11,10,11} },
{ codes = {8191,4087,2036,2024,1009,2030,2041,4088,8189,4093,2033,1000,488,240,492,1006,2034,4090,4084,1007,498,232,112,236,496,1002,2035,2027,491,234,26,8,25,238,495,2029,1008,242,115,11,0,10,113,243,2025,2031,494,239,24,9,27,235,489,2028,2038,1003,499,237,114,233,497,1005,2039,4086,2032,1001,493,241,490,1004,2040,4089,8188,4092,4085,2026,1011,1010,2037,4091,8190}, bits = {13,12,11,11,10,11,11,12,13,12,11,10,9,8,9,10,11,12,12,10,9,8,7,8,9,10,11,11,9,8,5,4,5,8,9,11,10,8,7,4,1,4,7,8,11,11,9,8,5,4,5,8,9,11,11,10,9,8,7,8,9,10,11,12,11,10,9,8,9,10,11,12,13,12,12,11,10,10,11,12,13} },
{ codes = {2046,1021,497,491,500,490,496,1020,2045,1014,485,234,108,113,104,240,486,1015,499,239,50,39,40,38,49,235,503,488,111,46,8,4,6,41,107,494,495,114,45,2,0,3,47,115,506,487,110,43,7,1,5,44,109,492,505,238,48,36,42,37,51,236,498,1016,484,237,106,112,105,116,241,1018,2047,1017,502,493,504,489,501,1019,2044}, bits = {11,10,9,9,9,9,9,10,11,10,9,8,7,7,7,8,9,10,9,8,6,6,6,6,6,8,9,9,7,6,4,4,4,6,7,9,9,7,6,4,4,4,6,7,9,9,7,6,4,4,4,6,7,9,9,8,6,6,6,6,6,8,9,10,9,8,7,7,7,7,8,10,11,10,9,9,9,9,9,10,11} },
{ codes = {0,5,55,116,242,491,1005,2039,4,12,53,113,236,238,494,501,54,52,114,234,241,489,499,1013,115,112,235,240,497,496,1004,1018,243,237,488,495,1007,1009,1017,2043,493,239,490,498,1011,1016,2041,2044,1006,492,500,1012,1015,2040,4093,4094,2038,1008,1010,1014,2042,2045,4092,4095}, bits = {1,3,6,7,8,9,10,11,3,4,6,7,8,8,9,9,6,6,7,8,8,9,9,10,7,7,8,8,9,9,10,10,8,8,9,9,10,10,10,11,9,8,9,9,10,10,11,11,10,9,9,10,10,11,12,12,11,10,10,10,11,11,12,12} },
{ codes = {14,5,16,48,111,241,506,1022,3,0,4,18,44,106,117,248,15,2,6,20,46,105,114,245,47,17,19,42,50,108,236,250,113,43,45,49,109,112,242,505,239,104,51,107,110,238,249,1020,504,116,115,237,240,246,502,509,1021,243,244,247,503,507,508,1023}, bits = {5,4,5,6,7,8,9,10,4,3,4,5,6,7,7,8,5,4,4,5,6,7,7,8,6,5,5,6,6,7,8,8,7,6,6,6,7,7,8,9,8,7,6,7,7,8,8,10,9,7,7,8,8,8,9,9,10,8,8,8,9,9,9,10} },
{ codes = {0,5,55,231,478,974,985,1992,1997,4040,4061,8164,8172,4,12,53,114,234,237,482,977,979,992,2008,4047,4053,54,52,113,232,236,481,975,989,987,2000,4039,4052,4068,230,112,233,477,483,978,988,1996,1994,2014,4056,4074,8155,479,235,476,486,981,990,1995,2013,2012,4045,4066,4071,8161,976,480,484,982,1989,2001,2011,4050,2016,4057,4075,8163,8169,1988,485,983,1990,1999,2010,4043,4058,4067,4073,8166,8179,8183,2003,984,993,2004,2009,4051,4062,8157,8153,8162,8170,8177,8182,2002,980,986,1991,2007,2018,4046,4059,8152,8174,16368,8180,16370,2017,991,1993,2006,4042,4048,4069,4070,8171,8175,16371,16372,16373,4064,1998,2005,4038,4049,4065,8160,8168,8176,16369,16376,16374,32764,4072,2015,4041,4055,4060,8156,8159,8173,8181,16377,16379,32765,32766,8167,4044,4054,4063,8158,8154,8165,8178,16378,16375,16380,16381,32767}, bits = {1,3,6,8,9,10,10,11,11,12,12,13,13,3,4,6,7,8,8,9,10,10,10,11,12,12,6,6,7,8,8,9,10,10,10,11,12,12,12,8,7,8,9,9,10,10,11,11,11,12,12,13,9,8,9,9,10,10,11,11,11,12,12,12,13,10,9,9,10,11,11,11,12,11,12,12,13,13,11,9,10,11,11,11,12,12,12,12,13,13,13,11,10,10,11,11,12,12,13,13,13,13,13,13,11,10,10,11,11,11,12,12,13,13,14,13,14,11,10,11,11,12,12,12,12,13,13,14,14,14,12,11,11,12,12,12,13,13,13,14,14,14,15,12,11,12,12,12,13,13,13,13,14,14,15,15,13,12,12,12,13,13,13,13,14,14,14,14,15} },
{ codes = {34,8,29,38,95,211,463,976,983,1005,2032,2038,4093,7,0,1,9,32,84,96,213,220,468,973,990,2023,28,2,6,12,30,40,91,205,217,462,476,985,1009,37,11,10,13,36,87,97,204,221,460,478,979,999,93,33,31,35,39,89,100,216,223,466,482,989,1006,209,85,41,86,88,98,206,224,226,474,980,995,2027,457,94,90,92,99,202,218,455,458,480,987,1000,2028,483,210,203,208,215,219,454,469,472,970,986,2026,2033,481,212,207,214,222,225,464,470,977,981,1010,2030,2043,1001,461,456,459,465,471,479,975,992,1007,2022,2040,4090,1003,477,467,473,475,978,972,988,1002,2029,2035,2041,4089,2034,974,484,971,984,982,994,997,2024,2036,2037,2039,4091,2042,1004,991,993,996,998,1008,2025,2031,4088,4094,4092,4095}, bits = {6,5,6,6,7,8,9,10,10,10,11,11,12,5,4,4,5,6,7,7,8,8,9,10,10,11,6,4,5,5,6,6,7,8,8,9,9,10,10,6,5,5,5,6,7,7,8,8,9,9,10,10,7,6,6,6,6,7,7,8,8,9,9,10,10,8,7,6,7,7,7,8,8,8,9,10,10,11,9,7,7,7,7,8,8,9,9,9,10,10,11,9,8,8,8,8,8,9,9,9,10,10,11,11,9,8,8,8,8,8,9,9,10,10,10,11,11,10,9,9,9,9,9,9,10,10,10,11,11,12,10,9,9,9,9,10,10,10,10,11,11,11,12,11,10,9,10,10,10,10,10,11,11,11,11,12,11,10,10,10,10,10,10,11,11,12,12,12,12} },
{ codes = {0,6,25,61,156,198,423,912,962,991,2022,2035,4091,2028,4090,4094,910,5,1,8,20,55,66,146,175,401,421,437,926,960,930,973,2006,174,23,7,9,24,57,64,142,163,184,409,428,449,945,918,958,970,157,60,21,22,26,59,68,145,165,190,406,430,441,929,913,933,981,148,154,54,56,58,65,140,155,176,195,414,427,444,927,911,937,975,147,191,62,63,67,69,158,167,185,404,418,442,451,934,935,955,980,159,416,143,141,144,152,166,182,196,415,431,447,921,959,948,969,999,168,438,171,164,170,178,194,197,408,420,440,908,932,964,966,989,1000,173,943,402,189,188,398,407,410,419,433,909,920,951,979,977,987,2013,180,990,425,411,412,417,426,429,435,907,946,952,974,993,992,2002,2021,183,2019,443,424,422,432,434,439,923,922,954,949,982,2007,996,2008,2026,186,2024,928,445,436,906,452,914,938,944,956,983,2004,2012,2011,2005,2032,193,2043,968,931,917,925,940,942,965,984,994,998,2020,2023,2016,2025,2039,400,2034,915,446,448,916,919,941,963,961,978,2010,2009,2015,2027,2036,2042,405,2040,957,924,939,936,947,953,976,995,997,2018,2014,2029,2033,2041,2044,403,4093,988,950,967,972,971,985,986,2003,2017,2030,2031,2037,2038,4092,4095,413,450,181,161,150,151,149,153,160,162,172,169,177,179,187,192,399,4}, bits = {4,5,6,7,8,8,9,10,10,10,11,11,12,11,12,12,10,5,4,5,6,7,7,8,8,9,9,9,10,10,10,10,11,8,6,5,5,6,7,7,8,8,8,9,9,9,10,10,10,10,8,7,6,6,6,7,7,8,8,8,9,9,9,10,10,10,10,8,8,7,7,7,7,8,8,8,8,9,9,9,10,10,10,10,8,8,7,7,7,7,8,8,8,9,9,9,9,10,10,10,10,8,9,8,8,8,8,8,8,8,9,9,9,10,10,10,10,10,8,9,8,8,8,8,8,8,9,9,9,10,10,10,10,10,10,8,10,9,8,8,9,9,9,9,9,10,10,10,10,10,10,11,8,10,9,9,9,9,9,9,9,10,10,10,10,10,10,11,11,8,11,9,9,9,9,9,9,10,10,10,10,10,11,10,11,11,8,11,10,9,9,10,9,10,10,10,10,10,11,11,11,11,11,8,11,10,10,10,10,10,10,10,10,10,10,11,11,11,11,11,9,11,10,9,9,10,10,10,10,10,10,11,11,11,11,11,11,9,11,10,10,10,10,10,10,10,10,10,11,11,11,11,11,11,9,12,10,10,10,10,10,10,10,11,11,11,11,11,11,12,12,9,9,8,8,8,8,8,8,8,8,8,8,8,8,8,8,9,5} }
}
T.swb1024 = {{0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,64,72,80,88,96,108,120,132,144,156,172,188,212,240,276,320,384,448,512,576,640,704,768,832,896,960,1024},{0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,64,72,80,88,96,108,120,132,144,156,172,188,212,240,276,320,384,448,512,576,640,704,768,832,896,960,1024},{0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,64,72,80,88,100,112,124,140,156,172,192,216,240,268,304,344,384,424,464,504,544,584,624,664,704,744,784,824,864,904,944,984,1024},{0,4,8,12,16,20,24,28,32,36,40,48,56,64,72,80,88,96,108,120,132,144,160,176,196,216,240,264,292,320,352,384,416,448,480,512,544,576,608,640,672,704,736,768,800,832,864,896,928,1024},{0,4,8,12,16,20,24,28,32,36,40,48,56,64,72,80,88,96,108,120,132,144,160,176,196,216,240,264,292,320,352,384,416,448,480,512,544,576,608,640,672,704,736,768,800,832,864,896,928,1024},{0,4,8,12,16,20,24,28,32,36,40,48,56,64,72,80,88,96,108,120,132,144,160,176,196,216,240,264,292,320,352,384,416,448,480,512,544,576,608,640,672,704,736,768,800,832,864,896,928,960,992,1024},{0,4,8,12,16,20,24,28,32,36,40,44,52,60,68,76,84,92,100,108,116,124,136,148,160,172,188,204,220,240,260,284,308,336,364,396,432,468,508,552,600,652,704,768,832,896,960,1024},{0,4,8,12,16,20,24,28,32,36,40,44,52,60,68,76,84,92,100,108,116,124,136,148,160,172,188,204,220,240,260,284,308,336,364,396,432,468,508,552,600,652,704,768,832,896,960,1024},{0,8,16,24,32,40,48,56,64,72,80,88,100,112,124,136,148,160,172,184,196,212,228,244,260,280,300,320,344,368,396,424,456,492,532,572,616,664,716,772,832,896,960,1024},{0,8,16,24,32,40,48,56,64,72,80,88,100,112,124,136,148,160,172,184,196,212,228,244,260,280,300,320,344,368,396,424,456,492,532,572,616,664,716,772,832,896,960,1024},{0,8,16,24,32,40,48,56,64,72,80,88,100,112,124,136,148,160,172,184,196,212,228,244,260,280,300,320,344,368,396,424,456,492,532,572,616,664,716,772,832,896,960,1024},{0,12,24,36,48,60,72,84,96,108,120,132,144,156,172,188,204,220,236,252,268,288,308,328,348,372,396,420,448,476,508,544,580,620,664,712,764,820,880,944,1024},{0,12,24,36,48,60,72,84,96,108,120,132,144,156,172,188,204,220,236,252,268,288,308,328,348,372,396,420,448,476,508,544,580,620,664,712,764,820,880,944,1024}}
T.swb128 = {{0,4,8,12,16,20,24,32,40,48,64,92,128},{0,4,8,12,16,20,24,32,40,48,64,92,128},{0,4,8,12,16,20,24,32,40,48,64,92,128},{0,4,8,12,16,20,28,36,44,56,68,80,96,112,128},{0,4,8,12,16,20,28,36,44,56,68,80,96,112,128},{0,4,8,12,16,20,28,36,44,56,68,80,96,112,128},{0,4,8,12,16,20,24,28,36,44,52,64,76,92,108,128},{0,4,8,12,16,20,24,28,36,44,52,64,76,92,108,128},{0,4,8,12,16,20,24,28,32,40,48,60,72,88,108,128},{0,4,8,12,16,20,24,28,32,40,48,60,72,88,108,128},{0,4,8,12,16,20,24,28,32,40,48,60,72,88,108,128},{0,4,8,12,16,20,24,28,36,44,52,60,72,88,108,128},{0,4,8,12,16,20,24,28,36,44,52,60,72,88,108,128}}
T.numSwb1024 = {41,41,47,49,49,51,47,47,43,43,43,40,40}
T.numSwb128 = {12,12,12,14,14,14,15,15,15,15,15,15,15}
T.tnsMax1024 = {31,31,34,40,42,51,46,46,42,42,42,39,39}
T.tnsMax128 = {9,9,10,14,14,14,14,14,14,14,14,14,14}
T.tns = {{0.00000000,-0.43388373,-0.78183150,-0.97492790,0.98480773,0.86602539,0.64278758,0.34202015},{0.00000000,-0.20791170,-0.40673664,-0.58778524,-0.74314481,-0.86602539,-0.95105654,-0.99452192,0.99573416,0.96182561,0.89516330,0.79801720,0.67369562,0.52643216,0.36124167,0.18374951},{0.00000000,-0.43388373,0.64278758,0.34202015},{0.00000000,-0.20791170,-0.40673664,-0.58778524,0.67369562,0.52643216,0.36124167,0.18374951}}

------------------------------------------------------------------------------------------------------------------------

local Aac = {}

local readu8 = buffer.readu8
local lshift, rshift, byteswap, band = bit32.lshift, bit32.rshift, bit32.byteswap, bit32.band
local floor, sqrt, abs, sin, cos, pi, min, max = math.floor, math.sqrt, math.abs, math.sin, math.cos, math.pi, math.min, math.max

local function fail(msg)
	error("AAC: " .. msg, 0)
end

Aac.Rates = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 }
local OBJECT_NAMES = { [1] = "AAC Main", [2] = "AAC-LC", [3] = "AAC SSR", [4] = "AAC LTP", [5] = "HE-AAC (SBR)", [6] = "AAC Scalable",
	[17] = "ER AAC-LC", [19] = "ER AAC LTP", [20] = "ER AAC Scalable", [22] = "ER BSAC", [23] = "AAC-LD", [29] = "HE-AAC v2 (PS)",
	[39] = "AAC-ELD", [42] = "xHE-AAC (USAC)" }

------------------------------------------------------------------------------------------------------------------------
-- bit reader over one access unit (copied into a padded work buffer)

local B = buffer.create(16)
local bitPos, bitEnd = 0, 0

local function load(src, pos, len)
	if buffer.len(B) < len + 8 then
		B = buffer.create(len + 1024)
	end
	buffer.fill(B, len, 0, 8)
	buffer.copy(B, 0, src, pos, len)
	bitPos, bitEnd = 0, len * 8
end

local function peek(n) -- n <= 24
	local v = byteswap(buffer.readu32(B, bitPos // 8))
	return rshift(lshift(v, bitPos % 8), 32 - n)
end

local function bits(n)
	if n == 0 then
		return 0
	end
	local v = rshift(lshift(byteswap(buffer.readu32(B, bitPos // 8)), bitPos % 8), 32 - n)
	bitPos += n
	return v
end

local function overread()
	if bitPos > bitEnd then
		fail("a frame is damaged (read past its end)")
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Huffman tables: 8-bit lookups; an entry is symbol * 32 + bits used at that level, or -(sub-table index)

local LB = 8
local function buildHuff(codes, lens)
	local subs = {}
	local root = table.create(256, false)
	for i = 1, #codes do
		local len, code = lens[i], codes[i]
		local t, rem = root, len
		while rem > LB do
			local prefix = rshift(code, rem - LB) % 256
			local e = t[prefix + 1]
			if e == false then
				table.insert(subs, table.create(256, false))
				e = -#subs
				t[prefix + 1] = e
			end
			t = subs[-e]
			rem -= LB
			code = code % (2 ^ rem)
		end
		local shift = LB - rem
		local base = lshift(code, shift)
		for k = 0, 2 ^ shift - 1 do
			t[base + k + 1] = (i - 1) * 32 + rem
		end
	end
	return { root = root, subs = subs }
end

local function huff(h)
	local t = h.root
	while true do
		local e = t[peek(LB) + 1]
		if e == false then
			fail("a frame is damaged (bad Huffman code)")
		end
		if e >= 0 then
			bitPos += e % 32
			return e // 32
		end
		bitPos += LB
		t = h.subs[-e]
	end
end

local SF_HUFF = buildHuff(T.sfCodes, T.sfBits)
local SPEC_HUFF = {}
for i = 1, 11 do
	SPEC_HUFF[i] = buildHuff(T.spectral[i].codes, T.spectral[i].bits)
end

-- codebook shapes: dimension, values per digit (mod), signed offset (0 = unsigned)
local CB_DIM = { 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2 }
local CB_MOD = { 3, 3, 3, 3, 9, 9, 8, 8, 13, 13, 17 }
local CB_OFF = { 1, 1, 0, 0, 4, 4, 0, 0, 0, 0, 0 }

-- |q|^(4/3)
local POW43 = table.create(8192 + 64, 0)
for q = 0, 8192 + 63 do
	POW43[q + 1] = q ^ (4 / 3)
end

------------------------------------------------------------------------------------------------------------------------
-- windows and the inverse MDCT

local function kbdRise(N, alpha)
	-- Kaiser-Bessel-derived window, rising half (N / 2 values)
	local function i0(x)
		local s, t, k = 1, 1, 1
		repeat
			t *= (x / (2 * k)) ^ 2
			s += t
			k += 1
		until t < s * 1e-12
		return s
	end
	local half = N // 2
	local w = table.create(half + 1, 0)
	local total = 0
	for j = 0, half do
		local r = (j - N / 4) / (N / 4)
		w[j + 1] = i0(pi * alpha * sqrt(max(0, 1 - r * r)))
		total += w[j + 1]
	end
	local out = table.create(half, 0)
	local acc = 0
	for n = 0, half - 1 do
		acc += w[n + 1]
		out[n + 1] = sqrt(acc / total)
	end
	return out
end
local function sineRise(N)
	local out = table.create(N // 2, 0)
	for n = 0, N // 2 - 1 do
		out[n + 1] = sin(pi / N * (n + 0.5))
	end
	return out
end
-- [shape + 1] = rising half; shape 0 = sine, 1 = KBD
local LONG_WIN = { sineRise(2048), kbdRise(2048, 4) }
local SHORT_WIN = { sineRise(256), kbdRise(256, 6) }

local plans = {}
local function plan(N)
	local p = plans[N]
	if p then
		return p
	end
	local M = N // 2
	local H = M // 2 -- complex FFT size
	local tc, ts = table.create(H, 0), table.create(H, 0)
	for j = 0, H - 1 do
		local a = -pi * (j + 0.125) / M
		tc[j + 1], ts[j + 1] = cos(a), sin(a)
	end
	local rev = table.create(H, 0)
	local logn = 0
	while 2 ^ logn < H do
		logn += 1
	end
	for i = 0, H - 1 do
		local r, x = 0, i
		for _ = 1, logn do
			r = r * 2 + x % 2
			x = x // 2
		end
		rev[i + 1] = r
	end
	-- twiddles for the FFT stages: w^k = exp(-2 pi i k / H)
	local wc, ws = table.create(H // 2, 0), table.create(H // 2, 0)
	for k = 0, H // 2 - 1 do
		wc[k + 1], ws[k + 1] = cos(-2 * pi * k / H), sin(-2 * pi * k / H)
	end
	p = { M = M, H = H, tc = tc, ts = ts, rev = rev, wc = wc, ws = ws, re = table.create(H, 0), im = table.create(H, 0),
		c = table.create(M, 0) }
	plans[N] = p
	return p
end

-- X[xo + 1 .. xo + N/2] -> out[oo + 1 .. oo + N], scaled by 2 / N (ISO 14496-3 4.6.18)
local function imdct(X, xo, N, out, oo)
	local p = plan(N)
	local M, H = p.M, p.H
	local tc, ts, rev, re, im, c = p.tc, p.ts, p.rev, p.re, p.im, p.c
	for j = 0, H - 1 do
		local a, b = X[xo + 2 * j + 1], X[xo + M - 2 * j]
		local cc, ss = tc[j + 1], ts[j + 1]
		local r = rev[j + 1] + 1
		re[r] = a * cc - b * ss
		im[r] = a * ss + b * cc
	end
	-- radix-2 FFT (decimation in time, input already bit-reversed)
	local wc, ws = p.wc, p.ws
	local size = 2
	while size <= H do
		local half = size // 2
		local step = H // size
		for start = 0, H - 1, size do
			for k = 0, half - 1 do
				local w = k * step + 1
				local cr, ci = wc[w], ws[w]
				local i1 = start + k + 1
				local i2 = i1 + half
				local xr, xi = re[i2], im[i2]
				local tr = xr * cr - xi * ci
				local ti = xr * ci + xi * cr
				local ur, ui = re[i1], im[i1]
				re[i1], im[i1] = ur + tr, ui + ti
				re[i2], im[i2] = ur - tr, ui - ti
			end
		end
		size *= 2
	end
	for j = 0, H - 1 do
		local cc, ss = tc[j + 1], ts[j + 1]
		local zr, zi = re[j + 1], im[j + 1]
		c[2 * j + 1] = zr * cc - zi * ss
		c[M - 2 * j] = -(zr * ss + zi * cc)
	end
	local scale = 2 / N
	local h = M // 2
	for n = 0, N - 1 do
		local q = n + h
		local v
		if q < M then
			v = c[q + 1]
		elseif q < 2 * M then
			v = -c[2 * M - q]
		else
			v = -c[q - 2 * M + 1]
		end
		out[oo + n + 1] = v * scale
	end
end
Aac.imdct = imdct

------------------------------------------------------------------------------------------------------------------------
-- one channel's spectrum (individual_channel_stream)

local ONLY_LONG, LONG_START, EIGHT_SHORT, LONG_STOP = 0, 1, 2, 3
local ZERO_HCB, NOISE_HCB, INTENSITY_HCB2, INTENSITY_HCB = 0, 13, 14, 15

local function newIcs()
	return { seq = 0, shape = 0, maxSfb = 0, numWindows = 1, numGroups = 1, groupLen = table.create(8, 1), swb = nil, numSwb = 0,
		tnsMax = 0 }
end

local function newChannel()
	return {
		ics = newIcs(),
		bandType = table.create(8 * 64, 0),
		scale = table.create(8 * 64, 0), -- per (group, band): dequantisation gain / noise energy / intensity gain
		q = table.create(1024, 0),
		coef = table.create(1024, 0),
		tns = { n = table.create(8, 0), length = {}, order = {}, dir = {}, coef = {} },
		tnsPresent = false,
		prevShape = 0,
		overlap = table.create(1024, 0),
		win = table.create(2048, 0),
	}
end

local function readIcsInfo(dec, ics)
	bits(1) -- reserved
	ics.seq = bits(2)
	ics.shape = bits(1)
	local sfi = dec.sfi
	if ics.seq == EIGHT_SHORT then
		ics.maxSfb = bits(4)
		local g = 1
		ics.groupLen[1] = 1
		for _ = 1, 7 do
			if bits(1) == 1 then
				ics.groupLen[g] += 1
			else
				g += 1
				ics.groupLen[g] = 1
			end
		end
		ics.numGroups = g
		ics.numWindows = 8
		ics.swb, ics.numSwb, ics.tnsMax = T.swb128[sfi], T.numSwb128[sfi], T.tnsMax128[sfi]
	else
		ics.maxSfb = bits(6)
		ics.numGroups, ics.numWindows = 1, 1
		ics.groupLen[1] = 1
		ics.swb, ics.numSwb, ics.tnsMax = T.swb1024[sfi], T.numSwb1024[sfi], T.tnsMax1024[sfi]
		if bits(1) == 1 then
			fail("this stream uses prediction (AAC Main / LTP), which isn't supported; re-save the sound as AAC-LC")
		end
	end
	if ics.maxSfb > ics.numSwb then
		fail("a frame is damaged (too many scale factor bands)")
	end
end

local function copyIcs(dst, src)
	dst.seq, dst.shape, dst.maxSfb, dst.numWindows, dst.numGroups = src.seq, src.shape, src.maxSfb, src.numWindows, src.numGroups
	dst.swb, dst.numSwb, dst.tnsMax = src.swb, src.numSwb, src.tnsMax
	for i = 1, 8 do
		dst.groupLen[i] = src.groupLen[i]
	end
end

local rand = 0x1f2e3d4c
local function nextRandom()
	rand = (rand * 1664525 + 1013904223) % 4294967296
	return rand >= 2147483648 and rand - 4294967296 or rand
end

local function readIcs(dec, ch, commonWindow)
	local ics = ch.ics
	local globalGain = bits(8)
	if not commonWindow then
		readIcsInfo(dec, ics)
	end
	local maxSfb, numGroups, swb = ics.maxSfb, ics.numGroups, ics.swb
	local bandType, scale = ch.bandType, ch.scale
	-- section data
	local sectBits = ics.seq == EIGHT_SHORT and 3 or 5
	local esc = 2 ^ sectBits - 1
	for g = 0, numGroups - 1 do
		local k = 0
		while k < maxSfb do
			local cb = bits(4)
			if cb == 12 then
				fail("a frame is damaged (band type 12)")
			end
			local stop = k
			local inc
			repeat
				inc = bits(sectBits)
				stop += inc
				overread()
			until inc ~= esc
			if stop > maxSfb then
				fail("a frame is damaged (section runs past the last band)")
			end
			for b = k, stop - 1 do
				bandType[g * maxSfb + b + 1] = cb
			end
			k = stop
		end
	end
	-- scale factors
	local off0, off1, off2 = globalGain, globalGain - 90, 0
	local firstNoise = true
	for g = 0, numGroups - 1 do
		for b = 0, maxSfb - 1 do
			local i = g * maxSfb + b + 1
			local cb = bandType[i]
			if cb == ZERO_HCB then
				scale[i] = 0
			elseif cb == INTENSITY_HCB or cb == INTENSITY_HCB2 then
				off2 += huff(SF_HUFF) - 60
				local p = math.clamp(off2, -155, 100)
				scale[i] = 2 ^ (-0.25 * p)
			elseif cb == NOISE_HCB then
				if firstNoise then
					off1 += bits(9) - 256
					firstNoise = false
				else
					off1 += huff(SF_HUFF) - 60
				end
				local p = math.clamp(off1, -100, 155)
				scale[i] = 2 ^ (0.25 * p)
			else
				off0 += huff(SF_HUFF) - 60
				if off0 < 0 or off0 > 255 then
					fail("a frame is damaged (scale factor out of range)")
				end
				scale[i] = 2 ^ (0.25 * (off0 - 100))
			end
		end
	end
	-- pulses
	local npulse = 0
	local ppos, pamp = dec.ppos, dec.pamp
	if bits(1) == 1 then
		if ics.seq == EIGHT_SHORT then
			fail("a frame is damaged (pulses in a short window)")
		end
		npulse = bits(2) + 1
		local startBand = bits(6)
		if startBand >= ics.numSwb then
			fail("a frame is damaged (pulse band)")
		end
		local pos = swb[startBand + 1]
		for p = 1, npulse do
			pos += bits(5)
			if pos >= 1024 then
				fail("a frame is damaged (pulse position)")
			end
			ppos[p] = pos
			pamp[p] = bits(4)
		end
	end
	-- temporal noise shaping
	ch.tnsPresent = bits(1) == 1
	if ch.tnsPresent then
		local tns = ch.tns
		local short = ics.seq == EIGHT_SHORT
		local maxOrder = short and 7 or 12
		for w = 1, ics.numWindows do
			local nf = bits(short and 1 or 2)
			tns.n[w] = nf
			if nf > 0 then
				local res = bits(1)
				tns.length[w] = tns.length[w] or {}
				tns.order[w] = tns.order[w] or {}
				tns.dir[w] = tns.dir[w] or {}
				tns.coef[w] = tns.coef[w] or {}
				for f = 1, nf do
					tns.length[w][f] = bits(short and 4 or 6)
					local order = bits(short and 3 or 5)
					if order > maxOrder then
						fail("a frame is damaged (TNS order)")
					end
					tns.order[w][f] = order
					if order > 0 then
						tns.dir[w][f] = bits(1)
						local compress = bits(1)
						local len = res + 3 - compress
						local map = T.tns[2 * compress + res + 1]
						local cf = tns.coef[w][f] or table.create(20, 0)
						tns.coef[w][f] = cf
						for i = 1, order do
							cf[i] = map[bits(len) + 1]
						end
					end
				end
			end
		end
	end
	if bits(1) == 1 then
		fail("this stream uses gain control (AAC SSR), which isn't supported")
	end
	-- spectral data (quantised values)
	local q = ch.q
	for i = 1, 1024 do
		q[i] = 0
	end
	local base = 0 -- first window of the group
	for g = 0, numGroups - 1 do
		local glen = ics.groupLen[g + 1]
		for b = 0, maxSfb - 1 do
			local cb = bandType[g * maxSfb + b + 1]
			local a, e = swb[b + 1], swb[b + 2]
			if cb >= 1 and cb <= 11 then
				local h = SPEC_HUFF[cb]
				local dim, mod, offs = CB_DIM[cb], CB_MOD[cb], CB_OFF[cb]
				for w = 0, glen - 1 do
					local o = (base + w) * 128
					local k = a
					while k < e do
						local idx = huff(h)
						if dim == 4 then
							local v1, v2, v3, v4 = idx // 27, (idx // 9) % 3, (idx // 3) % 3, idx % 3
							if offs > 0 then
								q[o + k + 1], q[o + k + 2], q[o + k + 3], q[o + k + 4] = v1 - 1, v2 - 1, v3 - 1, v4 - 1
							else
								if v1 ~= 0 and bits(1) == 1 then
									v1 = -v1
								end
								if v2 ~= 0 and bits(1) == 1 then
									v2 = -v2
								end
								if v3 ~= 0 and bits(1) == 1 then
									v3 = -v3
								end
								if v4 ~= 0 and bits(1) == 1 then
									v4 = -v4
								end
								q[o + k + 1], q[o + k + 2], q[o + k + 3], q[o + k + 4] = v1, v2, v3, v4
							end
							k += 4
						else
							local v1, v2 = idx // mod, idx % mod
							if offs > 0 then
								q[o + k + 1], q[o + k + 2] = v1 - offs, v2 - offs
							else
								local n1 = v1 ~= 0 and bits(1) == 1
								local n2 = v2 ~= 0 and bits(1) == 1
								if cb == 11 then
									if v1 == 16 then
										local n = 0
										while bits(1) == 1 do
											n += 1
											if n > 8 then
												fail("a frame is damaged (escape too long)")
											end
										end
										v1 = 2 ^ (n + 4) + bits(n + 4)
									end
									if v2 == 16 then
										local n = 0
										while bits(1) == 1 do
											n += 1
											if n > 8 then
												fail("a frame is damaged (escape too long)")
											end
										end
										v2 = 2 ^ (n + 4) + bits(n + 4)
									end
								end
								q[o + k + 1] = n1 and -v1 or v1
								q[o + k + 2] = n2 and -v2 or v2
							end
							k += 2
						end
					end
				end
			end
		end
		base += glen
	end
	overread()
	for p = 1, npulse do
		local i = ppos[p] + 1
		local v = q[i]
		q[i] = v > 0 and v + pamp[p] or v - pamp[p]
	end
	-- dequantise; noise bands get scaled noise
	local coef = ch.coef
	for i = 1, 1024 do
		coef[i] = 0
	end
	base = 0
	for g = 0, numGroups - 1 do
		local glen = ics.groupLen[g + 1]
		for b = 0, maxSfb - 1 do
			local i = g * maxSfb + b + 1
			local cb, s = bandType[i], scale[i]
			local a, e = swb[b + 1], swb[b + 2]
			if cb >= 1 and cb <= 11 then
				for w = 0, glen - 1 do
					local o = (base + w) * 128
					for k = o + a + 1, o + e do
						local v = q[k]
						if v ~= 0 then
							if v > 0 then
								coef[k] = (POW43[v + 1] or v ^ (4 / 3)) * s
							else
								coef[k] = -(POW43[1 - v] or (-v) ^ (4 / 3)) * s
							end
						end
					end
				end
			elseif cb == NOISE_HCB then
				for w = 0, glen - 1 do
					local o = (base + w) * 128
					local energy = 0
					for k = o + a + 1, o + e do
						local r = nextRandom()
						coef[k] = r
						energy += r * r
					end
					local f = s / sqrt(energy)
					for k = o + a + 1, o + e do
						coef[k] *= f
					end
				end
			end
		end
		base += glen
	end
end

-- all-pole TNS filters over the spectrum (ISO 14496-3 4.6.9)
local lpc, lpcTmp = table.create(20, 0), table.create(20, 0)
local function applyTns(ch)
	local ics, tns, coef = ch.ics, ch.tns, ch.coef
	local mmm = min(ics.tnsMax, ics.maxSfb)
	if mmm == 0 then
		return
	end
	local swb = ics.swb
	for w = 1, ics.numWindows do
		local bottom = ics.numSwb
		for f = 1, tns.n[w] do
			local top = bottom
			bottom = max(0, top - tns.length[w][f])
			local order = tns.order[w][f]
			if order > 0 then
				-- reflection coefficients -> LPC
				local cf = tns.coef[w][f]
				for i = 0, order - 1 do
					local r = -cf[i + 1]
					for j = 1, i do
						lpcTmp[j] = lpc[j]
					end
					lpc[i + 1] = r
					for j = 0, (i + 1) // 2 - 1 do
						local fwd, bwd = lpcTmp[j + 1], lpcTmp[i - j]
						lpc[j + 1] = fwd + r * bwd
						lpc[i - j] = bwd + r * fwd
					end
				end
				local start = swb[min(bottom, mmm) + 1]
				local stop = swb[min(top, mmm) + 1]
				local size = stop - start
				if size > 0 then
					local inc = 1
					if tns.dir[w][f] == 1 then
						inc = -1
						start = stop - 1
					end
					start += (w - 1) * 128
					for m = 0, size - 1 do
						local idx = start + m * inc + 1
						local v = coef[idx]
						for i = 1, min(m, order) do
							v -= coef[idx - i * inc] * lpc[i]
						end
						coef[idx] = v
					end
				end
			end
		end
	end
end

-- inverse MDCT, windowing and overlap-add: 1024 new samples into out[1 .. 1024]
local function synthesize(ch, out)
	local ics = ch.ics
	local seq, shape, prev = ics.seq, ics.shape, ch.prevShape
	local coef, win, overlap = ch.coef, ch.win, ch.overlap
	if seq == EIGHT_SHORT then
		for i = 1, 2048 do
			win[i] = 0
		end
		local tmp = ch.shortTmp or table.create(256, 0)
		ch.shortTmp = tmp
		local cur = SHORT_WIN[shape + 1]
		for w = 0, 7 do
			imdct(coef, w * 128, 256, tmp, 0)
			local left = w == 0 and SHORT_WIN[prev + 1] or cur
			local o = 448 + w * 128
			for n = 0, 127 do
				win[o + n + 1] += tmp[n + 1] * left[n + 1]
				win[o + 128 + n + 1] += tmp[128 + n + 1] * cur[128 - n]
			end
		end
	else
		imdct(coef, 0, 2048, win, 0)
		if seq == LONG_STOP then
			local left = SHORT_WIN[prev + 1]
			for n = 0, 447 do
				win[n + 1] = 0
			end
			for n = 0, 127 do
				win[448 + n + 1] *= left[n + 1]
			end
		else
			local left = LONG_WIN[prev + 1]
			for n = 0, 1023 do
				win[n + 1] *= left[n + 1]
			end
		end
		if seq == LONG_START then
			local right = SHORT_WIN[shape + 1]
			for n = 0, 127 do
				win[1472 + n + 1] *= right[128 - n]
			end
			for n = 1600, 2047 do
				win[n + 1] = 0
			end
		else
			local right = LONG_WIN[shape + 1]
			for n = 0, 1023 do
				win[1024 + n + 1] *= right[1024 - n]
			end
		end
	end
	for n = 1, 1024 do
		out[n] = win[n] + overlap[n]
		overlap[n] = win[1024 + n]
	end
	ch.prevShape = shape
end

------------------------------------------------------------------------------------------------------------------------
-- configuration

local function readConfigBits()
	local ot = bits(5)
	if ot == 31 then
		ot = 32 + bits(6)
	end
	return ot
end
local function readRate()
	local i = bits(4)
	if i == 15 then
		return nil, bits(12) * 4096 + bits(12)
	end
	return i, Aac.Rates[i + 1]
end

-- AudioSpecificConfig (the decoder setup stored in MP4 'esds') -> config
function Aac.parseConfig(asc)
	local b = type(asc) == "string" and buffer.fromstring(asc) or asc
	load(b, 0, buffer.len(b))
	local cfg = {}
	cfg.objectType = readConfigBits()
	local sfi, rate = readRate()
	cfg.channelConfig = bits(4)
	if cfg.objectType == 5 or cfg.objectType == 29 then
		cfg.sbr = true
		cfg.ps = cfg.objectType == 29
		local _, extRate = readRate()
		cfg.extensionRate = extRate
		cfg.objectType = readConfigBits()
	end
	cfg.sfi, cfg.sampleRate = sfi, rate
	local ot = cfg.objectType
	if ot ~= 2 and ot ~= 1 and ot ~= 4 then
		fail(("%s sound isn't supported (only AAC-LC and HE-AAC are)"):format(OBJECT_NAMES[ot] or ("object type " .. ot)))
	end
	-- GASpecificConfig
	if bits(1) == 1 then
		fail("960-sample frames aren't supported")
	end
	if bits(1) == 1 then
		bits(14) -- core coder delay
	end
	bits(1) -- extension flag
	if not sfi then
		-- an explicit rate: the nearest standard rate's tables
		local best, bi = math.huge, 4
		for i, r in ipairs(Aac.Rates) do
			if abs(r - rate) < best then
				best, bi = abs(r - rate), i - 1
			end
		end
		sfi = bi
		cfg.sfi = sfi
	end
	return cfg
end

-- skip a program_config_element
local function skipPce()
	bits(4) -- object type
	bits(4) -- sampling index
	local front, side, back, lfe, assoc, cc = bits(4), bits(4), bits(4), bits(2), bits(3), bits(4)
	if bits(1) == 1 then
		bits(4)
	end
	if bits(1) == 1 then
		bits(4)
	end
	if bits(1) == 1 then
		bits(3)
	end
	bitPos += (front + side + back) * 5 + lfe * 4 + assoc * 4 + cc * 5
	bitPos = (bitPos + 7) // 8 * 8
	bitPos += bits(8) * 8
end

------------------------------------------------------------------------------------------------------------------------
-- decoder

local Decoder = {}
Decoder.__index = Decoder

-- config: parseConfig output, or the AudioSpecificConfig bytes
function Aac.new(config)
	if type(config) ~= "table" then
		config = Aac.parseConfig(config)
	end
	local self = setmetatable({}, Decoder)
	self.config = config
	self.sfi = config.sfi + 1
	self.sampleRate = config.sampleRate
	self.elements = {} -- [type * 16 + tag + 1] = { channels }
	self.ppos, self.pamp = table.create(4, 0), table.create(4, 0)
	self.bufs = {}
	return self
end

local function element(self, kind, tag, n)
	local key = kind * 16 + tag + 1
	local e = self.elements[key]
	if not e then
		e = { kind = kind, tag = tag, ch = {}, out = {} }
		for i = 1, n do
			e.ch[i] = newChannel()
			e.out[i] = table.create(1024, 0)
		end
		self.elements[key] = e
	end
	return e
end

-- one raw AAC frame (an MP4 sample); returns left, right (arrays of 1024 samples, -1..1; right == left for mono)
function Decoder:decodeFrame(buf, pos, len)
	load(buf, pos, len)
	local decoded = {}
	while true do
		if bitPos + 3 > bitEnd then
			break
		end
		local id = bits(3)
		if id == 7 then
			break
		elseif id == 0 or id == 3 then -- SCE, LFE
			local e = element(self, id, bits(4), 1)
			readIcs(self, e.ch[1], false)
			if e.ch[1].tnsPresent then
				applyTns(e.ch[1])
			end
			synthesize(e.ch[1], e.out[1])
			table.insert(decoded, e)
		elseif id == 1 then -- CPE
			local e = element(self, id, bits(4), 2)
			local c0, c1 = e.ch[1], e.ch[2]
			local common = bits(1) == 1
			local msPresent = 0
			local ms = e.ms or table.create(8 * 64, 0)
			e.ms = ms
			if common then
				readIcsInfo(self, c0.ics)
				copyIcs(c1.ics, c0.ics)
				msPresent = bits(2)
				local n = c0.ics.numGroups * c0.ics.maxSfb
				if msPresent == 1 then
					for i = 1, n do
						ms[i] = bits(1)
					end
				elseif msPresent == 2 then
					for i = 1, n do
						ms[i] = 1
					end
				elseif msPresent == 3 then
					fail("a frame is damaged (ms_mask_present 3)")
				end
			end
			readIcs(self, c0, common)
			readIcs(self, c1, common)
			local ics = c1.ics
			local swb, maxSfb = ics.swb, ics.maxSfb
			if common and msPresent > 0 then
				local base = 0
				for g = 0, ics.numGroups - 1 do
					local glen = ics.groupLen[g + 1]
					for b = 0, maxSfb - 1 do
						local i = g * maxSfb + b + 1
						if ms[i] == 1 and c0.bandType[i] < NOISE_HCB and c1.bandType[i] < NOISE_HCB then
							for w = 0, glen - 1 do
								local o = (base + w) * 128
								local l, r = c0.coef, c1.coef
								for k = o + swb[b + 1] + 1, o + swb[b + 2] do
									local m, s = l[k], r[k]
									l[k], r[k] = m + s, m - s
								end
							end
						end
					end
					base += glen
				end
			end
			-- intensity stereo: the right channel's band is the left one scaled
			local base = 0
			for g = 0, ics.numGroups - 1 do
				local glen = ics.groupLen[g + 1]
				for b = 0, maxSfb - 1 do
					local i = g * maxSfb + b + 1
					local cb = c1.bandType[i]
					if cb == INTENSITY_HCB or cb == INTENSITY_HCB2 then
						local c = cb == INTENSITY_HCB and 1 or -1
						if msPresent > 0 and ms[i] == 1 then
							c = -c
						end
						local s = c * c1.scale[i]
						for w = 0, glen - 1 do
							local o = (base + w) * 128
							local l, r = c0.coef, c1.coef
							for k = o + swb[b + 1] + 1, o + swb[b + 2] do
								r[k] = l[k] * s
							end
						end
					end
				end
				base += glen
			end
			for k = 1, 2 do
				if e.ch[k].tnsPresent then
					applyTns(e.ch[k])
				end
				synthesize(e.ch[k], e.out[k])
			end
			table.insert(decoded, e)
		elseif id == 2 then
			fail("coupling channels (CCE) aren't supported")
		elseif id == 4 then -- DSE
			bits(4)
			local align = bits(1)
			local count = bits(8)
			if count == 255 then
				count += bits(8)
			end
			if align == 1 then
				bitPos = (bitPos + 7) // 8 * 8
			end
			bitPos += count * 8
		elseif id == 5 then
			skipPce()
		elseif id == 6 then -- FIL (SBR data lives here; the core is decoded without it)
			local count = bits(4)
			if count == 15 then
				count += bits(8) - 1
			end
			bitPos += count * 8
		end
		overread()
	end
	-- mix to stereo: the first pair is left / right, a single channel goes to both, others are folded in
	local L, R = self.bufs[1], self.bufs[2]
	if not L then
		L, R = table.create(1024, 0), table.create(1024, 0)
		self.bufs[1], self.bufs[2] = L, R
	end
	for n = 1, 1024 do
		L[n], R[n] = 0, 0
	end
	local stereo = false
	local mainUsed = false
	for _, e in ipairs(decoded) do
		if e.kind ~= 3 then
			local g = mainUsed and 0.7071 or 1
			if e.kind == 1 then
				local a, b = e.out[1], e.out[2]
				for n = 1, 1024 do
					L[n] += a[n] * g
					R[n] += b[n] * g
				end
				stereo = true
			else
				local a = e.out[1]
				for n = 1, 1024 do
					L[n] += a[n] * g
					R[n] += a[n] * g
				end
			end
			mainUsed = true
		end
	end
	local s = 1 / 32768
	for n = 1, 1024 do
		L[n] *= s
		R[n] *= s
	end
	return L, R, stereo, #decoded > 0
end

-- frames: { { pos, size } ... } in buf; options: Yield, MaxSeconds, Skip (samples to drop at the start: encoder delay)
-- -> signal { sampleRate, channels, length, data = { f32 buffers } } (AudioLab DSP.Signal layout)
function Aac.decodeFrames(config, buf, frames, options)
	options = options or {}
	local dec = Aac.new(config)
	local rate = dec.sampleRate
	local skip = options.Skip or 0
	local maxSamples = options.MaxSeconds and floor(options.MaxSeconds * rate) or math.huge
	local total = min(#frames * 1024 - skip, maxSamples)
	if total <= 0 then
		fail("the sound has no frames")
	end
	local left, right = buffer.create(total * 4), buffer.create(total * 4)
	local written = 0
	local stereo = false
	local t0 = os.clock()
	for i, f in ipairs(frames) do
		if written >= total then
			break
		end
		local ok, L, R, st = pcall(dec.decodeFrame, dec, buf, f.pos, f.size)
		if not ok then
			error(("%s (frame %d of %d)"):format(tostring(L), i, #frames), 0)
		end
		stereo = stereo or st
		for n = 1, 1024 do
			if skip > 0 then
				skip -= 1
			elseif written < total then
				buffer.writef32(left, written * 4, L[n])
				buffer.writef32(right, written * 4, R[n])
				written += 1
			end
		end
		if options.Yield and os.clock() - t0 > 0.02 then
			options.Yield()
			t0 = os.clock()
		end
	end
	local data = stereo and { left, right } or { left }
	return { sampleRate = rate, channels = #data, length = written, data = data }
end

-- ADTS stream (a raw .aac file) -> frames + config
function Aac.isAdts(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	return buffer.len(b) >= 7 and readu8(b, 0) == 0xFF and band(readu8(b, 1), 0xF6) == 0xF0
end

function Aac.parseAdts(bytes)
	local b = type(bytes) == "string" and buffer.fromstring(bytes) or bytes
	local len = buffer.len(b)
	local pos = 0
	local frames = {}
	local cfg
	while pos + 7 <= len do
		if readu8(b, pos) ~= 0xFF or band(readu8(b, pos + 1), 0xF6) ~= 0xF0 then
			break
		end
		local protectionAbsent = band(readu8(b, pos + 1), 1)
		local b2, b3, b4, b5, b6 = readu8(b, pos + 2), readu8(b, pos + 3), readu8(b, pos + 4), readu8(b, pos + 5), readu8(b, pos + 6)
		local profile = rshift(b2, 6) + 1
		local sfi = band(rshift(b2, 2), 15)
		local chc = band(b2, 1) * 4 + rshift(b3, 6)
		local flen = band(b3, 3) * 2048 + b4 * 8 + rshift(b5, 5)
		local blocks = band(b6, 3) + 1
		if blocks ~= 1 then
			fail("ADTS frames with several raw blocks aren't supported")
		end
		local head = protectionAbsent == 1 and 7 or 9
		if flen < head or pos + flen > len then
			break
		end
		if not cfg then
			if profile ~= 2 and profile ~= 1 then
				fail(("%s sound isn't supported (only AAC-LC is)"):format(OBJECT_NAMES[profile] or ("profile " .. profile)))
			end
			cfg = { objectType = profile, sfi = sfi, sampleRate = Aac.Rates[sfi + 1], channelConfig = chc }
		end
		table.insert(frames, { pos = pos + head, size = flen - head })
		pos += flen
	end
	if not cfg then
		fail("no ADTS frames found")
	end
	return cfg, frames
end

return Aac
