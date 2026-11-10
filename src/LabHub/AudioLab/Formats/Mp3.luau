--!native
--!optimize 2
-- Tables from minimp3 (CC0, https://github.com/lieff/minimp3). Arrays are 1-based copies of the C tables.
local T = {}
T.halfrate = {
	{
		{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 },
		{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 },
		{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128 },
	},
	{
		{ 0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160 },
		{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192 },
		{ 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224 },
	},
}
T.g_scf_long = {
	{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 },
	{ 12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0 },
	{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 },
	{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0 },
	{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 },
	{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0 },
	{ 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0 },
	{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0 },
}
T.g_scf_short = {
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30,
		30, 30, 40, 40, 40, 18, 18, 18, 0,
	},
	{
		8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2,
		2, 2, 2, 2, 2, 2, 26, 26, 26, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32,
		32, 42, 42, 42, 18, 18, 18, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32,
		32, 32, 44, 44, 44, 12, 12, 12, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30,
		30, 30, 40, 40, 40, 18, 18, 18, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22,
		22, 30, 30, 30, 56, 56, 56, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20,
		20, 26, 26, 26, 66, 66, 66, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34,
		34, 42, 42, 42, 12, 12, 12, 0,
	},
}
T.g_scf_mixed = {
	{
		6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30,
		40, 40, 40, 18, 18, 18, 0,
	},
	{
		12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2,
		2, 2, 2, 2, 2, 2, 2, 26, 26, 26, 0,
	},
	{
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42,
		42, 42, 18, 18, 18, 0,
	},
	{
		6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32,
		44, 44, 44, 12, 12, 12, 0,
	},
	{
		6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30,
		40, 40, 40, 18, 18, 18, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22,
		22, 30, 30, 30, 56, 56, 56, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20,
		20, 26, 26, 26, 66, 66, 66, 0,
	},
	{
		4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34,
		34, 42, 42, 42, 12, 12, 12, 0,
	},
}
T.g_scf_partitions = {
	{ 6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0 },
	{ 8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0 },
	{ 9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0 },
}
T.g_scfc_decode = { 0, 1, 2, 3, 12, 5, 6, 7, 9, 10, 11, 13, 14, 15, 18, 19 }
T.g_mod = { 5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1 }
T.g_preamp = { 1, 1, 1, 1, 2, 2, 3, 3, 3, 2 }
T.g_expfrac = { 9.31322575e-10, 7.83145814e-10, 6.58544508e-10, 5.53767716e-10 }
T.g_pow43 = {
	0, -1, -2.519842, -4.326749, -6.349604, -8.549880, -10.902724, -13.390518, -16.000000, -18.720754,
	-21.544347, -24.463781, -27.473142, -30.567351, -33.741992, -36.993181, 0, 1, 2.519842, 4.326749, 6.349604,
	8.549880, 10.902724, 13.390518, 16.000000, 18.720754, 21.544347, 24.463781, 27.473142, 30.567351, 33.741992,
	36.993181, 40.317474, 43.711787, 47.173345, 50.699631, 54.288352, 57.937408, 61.644865, 65.408941, 69.227979,
	73.100443, 77.024898, 81.000000, 85.024491, 89.097188, 93.216975, 97.382800, 101.593667, 105.848633,
	110.146801, 114.487321, 118.869381, 123.292209, 127.755065, 132.257246, 136.798076, 141.376907, 145.993119,
	150.646117, 155.335327, 160.060199, 164.820202, 169.614826, 174.443577, 179.305980, 184.201575, 189.129918,
	194.090580, 199.083145, 204.107210, 209.162385, 214.248292, 219.364564, 224.510845, 229.686789, 234.892058,
	240.126328, 245.389280, 250.680604, 256.000000, 261.347174, 266.721841, 272.123723, 277.552547, 283.008049,
	288.489971, 293.998060, 299.532071, 305.091761, 310.676898, 316.287249, 321.922592, 327.582707, 333.267377,
	338.976394, 344.709550, 350.466646, 356.247482, 362.051866, 367.879608, 373.730522, 379.604427, 385.501143,
	391.420496, 397.362314, 403.326427, 409.312672, 415.320884, 421.350905, 427.402579, 433.475750, 439.570269,
	445.685987, 451.822757, 457.980436, 464.158883, 470.357960, 476.577530, 482.817459, 489.077615, 495.357868,
	501.658090, 507.978156, 514.317941, 520.677324, 527.056184, 533.454404, 539.871867, 546.308458, 552.764065,
	559.238575, 565.731879, 572.243870, 578.774440, 585.323483, 591.890898, 598.476581, 605.080431, 611.702349,
	618.342238, 625.000000, 631.675540, 638.368763, 645.079578,
}
T.tabs = {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 785, 785,
	785, 785, 784, 784, 784, 784, 513, 513, 513, 513, 513, 513, 513, 513, 256, 256, 256, 256, 256, 256, 256, 256,
	256, 256, 256, 256, 256, 256, 256, 256, -255, 1313, 1298, 1282, 785, 785, 785, 785, 784, 784, 784, 784, 769,
	769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 290, 288,
	-255, 1313, 1298, 1282, 769, 769, 769, 769, 529, 529, 529, 529, 529, 529, 529, 529, 528, 528, 528, 528, 528,
	528, 528, 528, 512, 512, 512, 512, 512, 512, 512, 512, 290, 288, -253, -318, -351, -367, 785, 785, 785, 785,
	784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
	256, 256, 819, 818, 547, 547, 275, 275, 275, 275, 561, 560, 515, 546, 289, 274, 288, 258, -254, -287, 1329,
	1299, 1314, 1312, 1057, 1057, 1042, 1042, 1026, 1026, 784, 784, 784, 784, 529, 529, 529, 529, 529, 529, 529,
	529, 769, 769, 769, 769, 768, 768, 768, 768, 563, 560, 306, 306, 291, 259, -252, -413, -477, -542, 1298,
	-575, 1041, 1041, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
	256, 256, 256, 256, 256, 256, -383, -399, 1107, 1092, 1106, 1061, 849, 849, 789, 789, 1104, 1091, 773, 773,
	1076, 1075, 341, 340, 325, 309, 834, 804, 577, 577, 532, 532, 516, 516, 832, 818, 803, 816, 561, 561, 531,
	531, 515, 546, 289, 289, 288, 258, -252, -429, -493, -559, 1057, 1057, 1042, 1042, 529, 529, 529, 529, 529,
	529, 529, 529, 784, 784, 784, 784, 769, 769, 769, 769, 512, 512, 512, 512, 512, 512, 512, 512, -382, 1077,
	-415, 1106, 1061, 1104, 849, 849, 789, 789, 1091, 1076, 1029, 1075, 834, 834, 597, 581, 340, 340, 339, 324,
	804, 833, 532, 532, 832, 772, 818, 803, 817, 787, 816, 771, 290, 290, 290, 290, 288, 258, -253, -349, -414,
	-447, -463, 1329, 1299, -479, 1314, 1312, 1057, 1057, 1042, 1042, 1026, 1026, 785, 785, 785, 785, 784, 784,
	784, 784, 769, 769, 769, 769, 768, 768, 768, 768, -319, 851, 821, -335, 836, 850, 805, 849, 341, 340, 325,
	336, 533, 533, 579, 579, 564, 564, 773, 832, 578, 548, 563, 516, 321, 276, 306, 291, 304, 259, -251, -572,
	-733, -830, -863, -879, 1041, 1041, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256,
	256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527, -543, 1396, 1351, 1381, 1366, 1395, 1335, 1380,
	-559, 1334, 1138, 1138, 1063, 1063, 1350, 1392, 1031, 1031, 1062, 1062, 1364, 1363, 1120, 1120, 1333, 1348,
	881, 881, 881, 881, 375, 374, 359, 373, 343, 358, 341, 325, 791, 791, 1123, 1122, -703, 1105, 1045, -719,
	865, 865, 790, 790, 774, 774, 1104, 1029, 338, 293, 323, 308, -799, -815, 833, 788, 772, 818, 803, 816, 322,
	292, 307, 320, 561, 531, 515, 546, 289, 274, 288, 258, -251, -525, -605, -685, -765, -831, -846, 1298, 1057,
	1057, 1312, 1282, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 512, 512, 512, 512, 512, 512,
	512, 512, 1399, 1398, 1383, 1367, 1382, 1396, 1351, -511, 1381, 1366, 1139, 1139, 1079, 1079, 1124, 1124,
	1364, 1349, 1363, 1333, 882, 882, 882, 882, 807, 807, 807, 807, 1094, 1094, 1136, 1136, 373, 341, 535, 535,
	881, 775, 867, 822, 774, -591, 324, 338, -671, 849, 550, 550, 866, 864, 609, 609, 293, 336, 534, 534, 789,
	835, 773, -751, 834, 804, 308, 307, 833, 788, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290, 290,
	-252, -397, -477, -557, -622, -653, -719, -735, -750, 1329, 1299, 1314, 1057, 1057, 1042, 1042, 1312, 1282,
	1024, 1024, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, -383, 1127, 1141, 1111, 1126, 1140,
	1095, 1110, 869, 869, 883, 883, 1079, 1109, 882, 882, 375, 374, 807, 868, 838, 881, 791, -463, 867, 822, 368,
	263, 852, 837, 836, -543, 610, 610, 550, 550, 352, 336, 534, 534, 865, 774, 851, 821, 850, 805, 593, 533,
	579, 564, 773, 832, 578, 578, 548, 548, 577, 577, 307, 276, 306, 291, 516, 560, 259, 259, -250, -2107, -2507,
	-2764, -2909, -2974, -3007, -3023, 1041, 1041, 1040, 1040, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256,
	256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -767, -1052, -1213, -1277, -1358, -1405, -1469, -1535,
	-1550, -1582, -1614, -1647, -1662, -1694, -1726, -1759, -1774, -1807, -1822, -1854, -1886, 1565, -1919,
	-1935, -1951, -1967, 1731, 1730, 1580, 1717, -1983, 1729, 1564, -1999, 1548, -2015, -2031, 1715, 1595, -2047,
	1714, -2063, 1610, -2079, 1609, -2095, 1323, 1323, 1457, 1457, 1307, 1307, 1712, 1547, 1641, 1700, 1699,
	1594, 1685, 1625, 1442, 1442, 1322, 1322, -780, -973, -910, 1279, 1278, 1277, 1262, 1276, 1261, 1275, 1215,
	1260, 1229, -959, 974, 974, 989, 989, -943, 735, 478, 478, 495, 463, 506, 414, -1039, 1003, 958, 1017, 927,
	942, 987, 957, 431, 476, 1272, 1167, 1228, -1183, 1256, -1199, 895, 895, 941, 941, 1242, 1227, 1212, 1135,
	1014, 1014, 490, 489, 503, 487, 910, 1013, 985, 925, 863, 894, 970, 955, 1012, 847, -1343, 831, 755, 755,
	984, 909, 428, 366, 754, 559, -1391, 752, 486, 457, 924, 997, 698, 698, 983, 893, 740, 740, 908, 877, 739,
	739, 667, 667, 953, 938, 497, 287, 271, 271, 683, 606, 590, 712, 726, 574, 302, 302, 738, 736, 481, 286, 526,
	725, 605, 711, 636, 724, 696, 651, 589, 681, 666, 710, 364, 467, 573, 695, 466, 466, 301, 465, 379, 379, 709,
	604, 665, 679, 316, 316, 634, 633, 436, 436, 464, 269, 424, 394, 452, 332, 438, 363, 347, 408, 393, 448, 331,
	422, 362, 407, 392, 421, 346, 406, 391, 376, 375, 359, 1441, 1306, -2367, 1290, -2383, 1337, -2399, -2415,
	1426, 1321, -2431, 1411, 1336, -2447, -2463, -2479, 1169, 1169, 1049, 1049, 1424, 1289, 1412, 1352, 1319,
	-2495, 1154, 1154, 1064, 1064, 1153, 1153, 416, 390, 360, 404, 403, 389, 344, 374, 373, 343, 358, 372, 327,
	357, 342, 311, 356, 326, 1395, 1394, 1137, 1137, 1047, 1047, 1365, 1392, 1287, 1379, 1334, 1364, 1349, 1378,
	1318, 1363, 792, 792, 792, 792, 1152, 1152, 1032, 1032, 1121, 1121, 1046, 1046, 1120, 1120, 1030, 1030,
	-2895, 1106, 1061, 1104, 849, 849, 789, 789, 1091, 1076, 1029, 1090, 1060, 1075, 833, 833, 309, 324, 532,
	532, 832, 772, 818, 803, 561, 561, 531, 560, 515, 546, 289, 274, 288, 258, -250, -1179, -1579, -1836, -1996,
	-2124, -2253, -2333, -2413, -2477, -2542, -2574, -2607, -2622, -2655, 1314, 1313, 1298, 1312, 1282, 785, 785,
	785, 785, 1040, 1040, 1025, 1025, 768, 768, 768, 768, -766, -798, -830, -862, -895, -911, -927, -943, -959,
	-975, -991, -1007, -1023, -1039, -1055, -1070, 1724, 1647, -1103, -1119, 1631, 1767, 1662, 1738, 1708, 1723,
	-1135, 1780, 1615, 1779, 1599, 1677, 1646, 1778, 1583, -1151, 1777, 1567, 1737, 1692, 1765, 1722, 1707, 1630,
	1751, 1661, 1764, 1614, 1736, 1676, 1763, 1750, 1645, 1598, 1721, 1691, 1762, 1706, 1582, 1761, 1566, -1167,
	1749, 1629, 767, 766, 751, 765, 494, 494, 735, 764, 719, 749, 734, 763, 447, 447, 748, 718, 477, 506, 431,
	491, 446, 476, 461, 505, 415, 430, 475, 445, 504, 399, 460, 489, 414, 503, 383, 474, 429, 459, 502, 502, 746,
	752, 488, 398, 501, 473, 413, 472, 486, 271, 480, 270, -1439, -1455, 1357, -1471, -1487, -1503, 1341, 1325,
	-1519, 1489, 1463, 1403, 1309, -1535, 1372, 1448, 1418, 1476, 1356, 1462, 1387, -1551, 1475, 1340, 1447,
	1402, 1386, -1567, 1068, 1068, 1474, 1461, 455, 380, 468, 440, 395, 425, 410, 454, 364, 467, 466, 464, 453,
	269, 409, 448, 268, 432, 1371, 1473, 1432, 1417, 1308, 1460, 1355, 1446, 1459, 1431, 1083, 1083, 1401, 1416,
	1458, 1445, 1067, 1067, 1370, 1457, 1051, 1051, 1291, 1430, 1385, 1444, 1354, 1415, 1400, 1443, 1082, 1082,
	1173, 1113, 1186, 1066, 1185, 1050, -1967, 1158, 1128, 1172, 1097, 1171, 1081, -1983, 1157, 1112, 416, 266,
	375, 400, 1170, 1142, 1127, 1065, 793, 793, 1169, 1033, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1140, 898,
	898, 808, 808, 897, 897, 792, 792, 1095, 1152, 1032, 1125, 1110, 1139, 1079, 1124, 882, 807, 838, 881, 853,
	791, -2319, 867, 368, 263, 822, 852, 837, 866, 806, 865, -2399, 851, 352, 262, 534, 534, 821, 836, 594, 594,
	549, 549, 593, 593, 533, 533, 848, 773, 579, 579, 564, 578, 548, 563, 276, 276, 577, 576, 306, 291, 516, 560,
	305, 305, 275, 259, -251, -892, -2058, -2620, -2828, -2957, -3023, -3039, 1041, 1041, 1040, 1040, 769, 769,
	769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527, -543,
	-559, 1530, -575, -591, 1528, 1527, 1407, 1526, 1391, 1023, 1023, 1023, 1023, 1525, 1375, 1268, 1268, 1103,
	1103, 1087, 1087, 1039, 1039, 1523, -604, 815, 815, 815, 815, 510, 495, 509, 479, 508, 463, 507, 447, 431,
	505, 415, 399, -734, -782, 1262, -815, 1259, 1244, -831, 1258, 1228, -847, -863, 1196, -879, 1253, 987, 987,
	748, -767, 493, 493, 462, 477, 414, 414, 686, 669, 478, 446, 461, 445, 474, 429, 487, 458, 412, 471, 1266,
	1264, 1009, 1009, 799, 799, -1019, -1276, -1452, -1581, -1677, -1757, -1821, -1886, -1933, -1997, 1257, 1257,
	1483, 1468, 1512, 1422, 1497, 1406, 1467, 1496, 1421, 1510, 1134, 1134, 1225, 1225, 1466, 1451, 1374, 1405,
	1252, 1252, 1358, 1480, 1164, 1164, 1251, 1251, 1238, 1238, 1389, 1465, -1407, 1054, 1101, -1423, 1207,
	-1439, 830, 830, 1248, 1038, 1237, 1117, 1223, 1148, 1236, 1208, 411, 426, 395, 410, 379, 269, 1193, 1222,
	1132, 1235, 1221, 1116, 976, 976, 1192, 1162, 1177, 1220, 1131, 1191, 963, 963, -1647, 961, 780, -1663, 558,
	558, 994, 993, 437, 408, 393, 407, 829, 978, 813, 797, 947, -1743, 721, 721, 377, 392, 844, 950, 828, 890,
	706, 706, 812, 859, 796, 960, 948, 843, 934, 874, 571, 571, -1919, 690, 555, 689, 421, 346, 539, 539, 944,
	779, 918, 873, 932, 842, 903, 888, 570, 570, 931, 917, 674, 674, -2575, 1562, -2591, 1609, -2607, 1654, 1322,
	1322, 1441, 1441, 1696, 1546, 1683, 1593, 1669, 1624, 1426, 1426, 1321, 1321, 1639, 1680, 1425, 1425, 1305,
	1305, 1545, 1668, 1608, 1623, 1667, 1592, 1638, 1666, 1320, 1320, 1652, 1607, 1409, 1409, 1304, 1304, 1288,
	1288, 1664, 1637, 1395, 1395, 1335, 1335, 1622, 1636, 1394, 1394, 1319, 1319, 1606, 1621, 1392, 1392, 1137,
	1137, 1137, 1137, 345, 390, 360, 375, 404, 373, 1047, -2751, -2767, -2783, 1062, 1121, 1046, -2799, 1077,
	-2815, 1106, 1061, 789, 789, 1105, 1104, 263, 355, 310, 340, 325, 354, 352, 262, 339, 324, 1091, 1076, 1029,
	1090, 1060, 1075, 833, 833, 788, 788, 1088, 1028, 818, 818, 803, 803, 561, 561, 531, 531, 816, 771, 546, 546,
	289, 274, 288, 258, -253, -317, -381, -446, -478, -509, 1279, 1279, -811, -1179, -1451, -1756, -1900, -2028,
	-2189, -2253, -2333, -2414, -2445, -2511, -2526, 1313, 1298, -2559, 1041, 1041, 1040, 1040, 1025, 1025, 1024,
	1024, 1022, 1007, 1021, 991, 1020, 975, 1019, 959, 687, 687, 1018, 1017, 671, 671, 655, 655, 1016, 1015, 639,
	639, 758, 758, 623, 623, 757, 607, 756, 591, 755, 575, 754, 559, 543, 543, 1009, 783, -575, -621, -685, -749,
	496, -590, 750, 749, 734, 748, 974, 989, 1003, 958, 988, 973, 1002, 942, 987, 957, 972, 1001, 926, 986, 941,
	971, 956, 1000, 910, 985, 925, 999, 894, 970, -1071, -1087, -1102, 1390, -1135, 1436, 1509, 1451, 1374,
	-1151, 1405, 1358, 1480, 1420, -1167, 1507, 1494, 1389, 1342, 1465, 1435, 1450, 1326, 1505, 1310, 1493, 1373,
	1479, 1404, 1492, 1464, 1419, 428, 443, 472, 397, 736, 526, 464, 464, 486, 457, 442, 471, 484, 482, 1357,
	1449, 1434, 1478, 1388, 1491, 1341, 1490, 1325, 1489, 1463, 1403, 1309, 1477, 1372, 1448, 1418, 1433, 1476,
	1356, 1462, 1387, -1439, 1475, 1340, 1447, 1402, 1474, 1324, 1461, 1371, 1473, 269, 448, 1432, 1417, 1308,
	1460, -1711, 1459, -1727, 1441, 1099, 1099, 1446, 1386, 1431, 1401, -1743, 1289, 1083, 1083, 1160, 1160,
	1458, 1445, 1067, 1067, 1370, 1457, 1307, 1430, 1129, 1129, 1098, 1098, 268, 432, 267, 416, 266, 400, -1887,
	1144, 1187, 1082, 1173, 1113, 1186, 1066, 1050, 1158, 1128, 1143, 1172, 1097, 1171, 1081, 420, 391, 1157,
	1112, 1170, 1142, 1127, 1065, 1169, 1049, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1154, 1064, 1153, 1140,
	1095, 1048, -2159, 1125, 1110, 1137, -2175, 823, 823, 1139, 1138, 807, 807, 384, 264, 368, 263, 868, 838,
	853, 791, 867, 822, 852, 837, 866, 806, 865, 790, -2319, 851, 821, 836, 352, 262, 850, 805, 849, -2399, 533,
	533, 835, 820, 336, 261, 578, 548, 563, 577, 532, 532, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290,
	290, 288, 258,
}
T.tab32 = {
	130, 162, 193, 209, 44, 28, 76, 140, 9, 9, 9, 9, 9, 9, 9, 9, 190, 254, 222, 238, 126, 94, 157, 157, 109, 61,
	173, 205,
}
T.tab33 = { 252, 236, 220, 204, 188, 172, 156, 140, 124, 108, 92, 76, 60, 44, 28, 12 }
T.tabindex = {
	0, 32, 64, 98, 0, 132, 180, 218, 292, 364, 426, 538, 648, 746, 0, 1126, 1460, 1460, 1460, 1460, 1460, 1460,
	1460, 1460, 1842, 1842, 1842, 1842, 1842, 1842, 1842, 1842,
}
T.g_linbits = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 6, 8, 10, 13, 4, 5, 6, 7, 8, 9, 11, 13 }
T.g_pan = {
	0, 1, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460, 0.36602540, 0.78867513,
	0.21132487, 1, 0,
}
T.g_aa = {
	{ 0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316 },
	{ 0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997 },
}
T.g_twid9 = {
	0.73727734, 0.79335334, 0.84339145, 0.88701083, 0.92387953, 0.95371695, 0.97629601, 0.99144486, 0.99904822,
	0.67559021, 0.60876143, 0.53729961, 0.46174861, 0.38268343, 0.30070580, 0.21643961, 0.13052619, 0.04361938,
}
T.g_twid3 = { 0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619 }
T.g_mdct_window = {
	{
		0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734,
		0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021,
	},
	{ 1, 1, 1, 1, 1, 1, 0.99144486, 0.92387953, 0.79335334, 0, 0, 0, 0, 0, 0, 0.13052619, 0.38268343, 0.60876143 },
}
T.g_sec = {
	10.19000816, 0.50060302, 0.50241929, 3.40760851, 0.50547093, 0.52249861, 2.05778098, 0.51544732, 0.56694406,
	1.48416460, 0.53104258, 0.64682180, 1.16943991, 0.55310392, 0.78815460, 0.97256821, 0.58293498, 1.06067765,
	0.83934963, 0.62250412, 1.72244716, 0.74453628, 0.67480832, 5.10114861,
}
T.g_win = {
	-1, 26, -31, 208, 218, 401, -519, 2063, 2000, 4788, -5517, 7134, 5959, 35640, -39336, 74992, -1, 24, -35,
	202, 222, 347, -581, 2080, 1952, 4425, -5879, 7640, 5288, 33791, -41176, 74856, -1, 21, -38, 196, 225, 294,
	-645, 2087, 1893, 4063, -6237, 8092, 4561, 31947, -43006, 74630, -1, 19, -41, 190, 227, 244, -711, 2085,
	1822, 3705, -6589, 8492, 3776, 30112, -44821, 74313, -1, 17, -45, 183, 228, 197, -779, 2075, 1739, 3351,
	-6935, 8840, 2935, 28289, -46617, 73908, -1, 16, -49, 176, 228, 153, -848, 2057, 1644, 3004, -7271, 9139,
	2037, 26482, -48390, 73415, -2, 14, -53, 169, 227, 111, -919, 2032, 1535, 2663, -7597, 9389, 1082, 24694,
	-50137, 72835, -2, 13, -58, 161, 224, 72, -991, 2001, 1414, 2330, -7910, 9592, 70, 22929, -51853, 72169, -2,
	11, -63, 154, 221, 36, -1064, 1962, 1280, 2006, -8209, 9750, -998, 21189, -53534, 71420, -2, 10, -68, 147,
	215, 2, -1137, 1919, 1131, 1692, -8491, 9863, -2122, 19478, -55178, 70590, -3, 9, -73, 139, 208, -29, -1210,
	1870, 970, 1388, -8755, 9935, -3300, 17799, -56778, 69679, -3, 8, -79, 132, 200, -57, -1283, 1817, 794, 1095,
	-8998, 9966, -4533, 16155, -58333, 68692, -4, 7, -85, 125, 189, -83, -1356, 1759, 605, 814, -9219, 9959,
	-5818, 14548, -59838, 67629, -4, 7, -91, 117, 177, -106, -1428, 1698, 402, 545, -9416, 9916, -7154, 12980,
	-61289, 66494, -5, 6, -97, 111, 163, -127, -1498, 1634, 185, 288, -9585, 9838, -8540, 11455, -62684, 65290,
}
T.g_hz = { 44100, 48000, 32000 }

-- MPEG-1 / MPEG-2 / MPEG-2.5 audio decoder (Layer III, and Layer I / II: MP2) in pure Luau (no Roblox APIs).
-- A port of minimp3 by Lion (lieff), CC0 / public domain: https://github.com/lieff/minimp3
--
--   local result = Mp3.decode(bytes: buffer, options?)
--     options.Yield    function called between frames when options.Budget seconds have passed
--     options.Budget   seconds of work between Yield calls (default 0.01)
--     options.MaxSeconds  stop after this much audio (optional)
--   result = { sampleRate, channels, length (samples per channel), data = { buffer f32 per channel },
--              bitrate (kbps of the first frame), frames, delay, padding }
--   Mp3.probe(bytes) -> { sampleRate, channels, bitrate, layer, offset } or nil
--
-- Gapless: ID3v2/ID3v1 tags are skipped and a Xing/Info/LAME header's encoder delay and padding are
-- trimmed, as minimp3_ex does.

local Mp3 = {}

local band, bor, bxor, lsh, rsh, btest, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift, bit32.btest, bit32.bnot
local readu8 = buffer.readu8
local min, max = math.min, math.max

local MAX_FREE_FORMAT_FRAME_SIZE = 2304
local MAX_FRAME_SYNC_MATCHES = 10
local MAX_BITRESERVOIR_BYTES = 511
local SHORT_BLOCK_TYPE, STOP_BLOCK_TYPE = 2, 3
local BITS_DEQUANTIZER_OUT = -1
local MAX_SCFI = 44

local tabs, tab32, tab33, tabindex, linbitsT = T.tabs, T.tab32, T.tab33, T.tabindex, T.g_linbits
local pow43 = T.g_pow43

-- header ------------------------------------------------------------------------------------
-- h = { b0, b1, b2, b3 } (the four header bytes)
local function hdrAt(b, o, h)
	h = h or table.create(4, 0)
	h[1], h[2], h[3], h[4] = readu8(b, o), readu8(b, o + 1), readu8(b, o + 2), readu8(b, o + 3)
	return h
end
local function isMono(h) return band(h[4], 0xC0) == 0xC0 end
local function isMsStereo(h) return band(h[4], 0xE0) == 0x60 end
local function isFreeFormat(h) return band(h[3], 0xF0) == 0 end
local function isCrc(h) return not btest(h[2], 1) end
local function testPadding(h) return btest(h[3], 2) end
local function isMpeg1(h) return btest(h[2], 8) end
local function notMpeg25(h) return btest(h[2], 0x10) end
local function testIStereo(h) return btest(h[4], 0x10) end
local function testMsStereo(h) return btest(h[4], 0x20) end
local function getLayer(h) return band(rsh(h[2], 1), 3) end
local function getBitrate(h) return rsh(h[3], 4) end
local function getSampleRate(h) return band(rsh(h[3], 2), 3) end
local function getMySampleRate(h) return getSampleRate(h) + (band(rsh(h[2], 3), 1) + band(rsh(h[2], 4), 1)) * 3 end
local function isFrame576(h) return band(h[2], 14) == 2 end
local function isLayer1(h) return band(h[2], 6) == 6 end

local function hdrValidAt(b, o)
	local h1, h2 = readu8(b, o + 1), readu8(b, o + 2)
	return readu8(b, o) == 0xFF and (band(h1, 0xF0) == 0xF0 or band(h1, 0xFE) == 0xE2)
		and band(rsh(h1, 1), 3) ~= 0 and rsh(h2, 4) ~= 15 and band(rsh(h2, 2), 3) ~= 3
end
local function hdrCompare(h1, b, o)
	if not hdrValidAt(b, o) then
		return false
	end
	local b1, b2 = readu8(b, o + 1), readu8(b, o + 2)
	return band(bxor(h1[2], b1), 0xFE) == 0 and band(bxor(h1[3], b2), 0x0C) == 0
		and isFreeFormat(h1) == (band(b2, 0xF0) == 0)
end
local function bitrateKbps(h)
	return 2 * T.halfrate[isMpeg1(h) and 2 or 1][getLayer(h)][getBitrate(h) + 1]
end
local function sampleRateHz(h)
	local hz = T.g_hz[getSampleRate(h) + 1]
	if not isMpeg1(h) then
		hz = rsh(hz, 1)
	end
	if not notMpeg25(h) then
		hz = rsh(hz, 1)
	end
	return hz
end
local function frameSamples(h)
	return isLayer1(h) and 384 or rsh(1152, isFrame576(h) and 1 or 0)
end
local function frameBytes(h, freeFormatSize)
	local fb = frameSamples(h) * bitrateKbps(h) * 125 // sampleRateHz(h)
	if isLayer1(h) then
		fb = band(fb, bnot(3))
	end
	return (fb ~= 0) and fb or freeFormatSize
end
local function hdrPadding(h)
	return testPadding(h) and (isLayer1(h) and 4 or 1) or 0
end

-- bitstream ---------------------------------------------------------------------------------
-- bs = { buf, base (byte offset), pos (bits), limit (bits) }
local function getBits(bs, n)
	local pos = bs.pos
	local s = band(pos, 7)
	local shl = n + s
	local p = bs.base + rsh(pos, 3)
	bs.pos = pos + n
	if pos + n > bs.limit then
		return 0
	end
	local buf = bs.buf
	local nxt = band(readu8(buf, p), rsh(255, s))
	p += 1
	local cache = 0
	shl -= 8
	while shl > 0 do
		cache = bor(cache, lsh(nxt, shl))
		nxt = readu8(buf, p)
		p += 1
		shl -= 8
	end
	return bor(cache, rsh(nxt, -shl))
end

-- side info ---------------------------------------------------------------------------------
local function newGranule()
	return {
		sfbtab = nil, part_23_length = 0, big_values = 0, scalefac_compress = 0, global_gain = 0,
		block_type = 0, mixed_block_flag = 0, n_long_sfb = 0, n_short_sfb = 0,
		table_select = { 0, 0, 0 }, region_count = { 0, 0, 0 }, subblock_gain = { 0, 0, 0 },
		preflag = 0, scalefac_scale = 0, count1_table = 0, scfsi = 0,
	}
end

local function readSideInfo(bs, grs, h)
	local mpeg1 = isMpeg1(h)
	local srIdx = getMySampleRate(h)
	if srIdx ~= 0 then
		srIdx -= 1
	end
	local mono = isMono(h)
	local grCount = mono and 1 or 2
	local mainDataBegin, scfsi = 0, 0
	local part23sum = 0
	if mpeg1 then
		grCount *= 2
		mainDataBegin = getBits(bs, 9)
		scfsi = getBits(bs, 7 + grCount)
	else
		mainDataBegin = rsh(getBits(bs, 8 + grCount), grCount)
	end
	local gi = 1
	repeat
		local gr = grs[gi]
		if mono then
			scfsi = lsh(scfsi, 4)
		end
		gr.part_23_length = getBits(bs, 12)
		part23sum += gr.part_23_length
		gr.big_values = getBits(bs, 9)
		if gr.big_values > 288 then
			return -1
		end
		gr.global_gain = getBits(bs, 8)
		gr.scalefac_compress = getBits(bs, mpeg1 and 4 or 9)
		gr.sfbtab = T.g_scf_long[srIdx + 1]
		gr.n_long_sfb = 22
		gr.n_short_sfb = 0
		local tables
		if getBits(bs, 1) ~= 0 then
			gr.block_type = getBits(bs, 2)
			if gr.block_type == 0 then
				return -1
			end
			gr.mixed_block_flag = getBits(bs, 1)
			gr.region_count[1] = 7
			gr.region_count[2] = 255
			if gr.block_type == SHORT_BLOCK_TYPE then
				scfsi = band(scfsi, 0x0F0F)
				if gr.mixed_block_flag == 0 then
					gr.region_count[1] = 8
					gr.sfbtab = T.g_scf_short[srIdx + 1]
					gr.n_long_sfb = 0
					gr.n_short_sfb = 39
				else
					gr.sfbtab = T.g_scf_mixed[srIdx + 1]
					gr.n_long_sfb = mpeg1 and 8 or 6
					gr.n_short_sfb = 30
				end
			end
			tables = lsh(getBits(bs, 10), 5)
			gr.subblock_gain[1] = getBits(bs, 3)
			gr.subblock_gain[2] = getBits(bs, 3)
			gr.subblock_gain[3] = getBits(bs, 3)
		else
			gr.block_type = 0
			gr.mixed_block_flag = 0
			tables = getBits(bs, 15)
			gr.region_count[1] = getBits(bs, 4)
			gr.region_count[2] = getBits(bs, 3)
			gr.region_count[3] = 255
		end
		gr.table_select[1] = rsh(tables, 10)
		gr.table_select[2] = band(rsh(tables, 5), 31)
		gr.table_select[3] = band(tables, 31)
		gr.preflag = mpeg1 and getBits(bs, 1) or ((gr.scalefac_compress >= 500) and 1 or 0)
		gr.scalefac_scale = getBits(bs, 1)
		gr.count1_table = getBits(bs, 1)
		gr.scfsi = band(rsh(scfsi, 12), 15)
		scfsi = lsh(scfsi, 4)
		gi += 1
		grCount -= 1
	until grCount == 0
	if part23sum + bs.pos > bs.limit + mainDataBegin * 8 then
		return -1
	end
	return mainDataBegin
end

-- scalefactors ------------------------------------------------------------------------------
local function readScalefactors(scf, ist, scfSize, part, partOff, bs, scfsi)
	local so, io = 0, 0
	for i = 0, 3 do
		local cnt = part[partOff + i + 1]
		if not cnt or cnt == 0 then
			break
		end
		if btest(scfsi, 8) then
			for k = 1, cnt do
				scf[so + k] = ist[io + k]
			end
		else
			local bits = scfSize[i + 1]
			if bits == 0 then
				for k = 1, cnt do
					scf[so + k] = 0
					ist[io + k] = 0
				end
			else
				local maxScf = (scfsi < 0) and (lsh(1, bits) - 1) or -1
				for k = 1, cnt do
					local s = getBits(bs, bits)
					ist[io + k] = (s == maxScf) and 255 or s
					scf[so + k] = s
				end
			end
		end
		io += cnt
		so += cnt
		scfsi *= 2
	end
	scf[so + 1], scf[so + 2], scf[so + 3] = 0, 0, 0
end

local expfrac = T.g_expfrac
local function ldexpQ2(y, e2)
	repeat
		local e = min(120, e2)
		y *= expfrac[band(e, 3) + 1] * rsh(lsh(1, 30), rsh(e, 2))
		e2 -= e
	until e2 <= 0
	return y
end

local function decodeScalefactors(h, ist, bs, gr, scf, ch, iscf, scfSize)
	local partRow = T.g_scf_partitions[((gr.n_short_sfb ~= 0) and 1 or 0) + ((gr.n_long_sfb == 0) and 1 or 0) + 1]
	local partOff = 0
	local scfShift = gr.scalefac_scale + 1
	local scfsi = gr.scfsi
	if isMpeg1(h) then
		local part = T.g_scfc_decode[gr.scalefac_compress + 1]
		scfSize[1] = rsh(part, 2)
		scfSize[2] = scfSize[1]
		scfSize[3] = band(part, 3)
		scfSize[4] = scfSize[3]
	else
		local istFlag = (testIStereo(h) and ch ~= 0) and 1 or 0
		local sfc = rsh(gr.scalefac_compress, istFlag)
		local k = istFlag * 3 * 4
		local mod = T.g_mod
		while sfc >= 0 do
			local modprod = 1
			for i = 3, 0, -1 do
				scfSize[i + 1] = (sfc // modprod) % mod[k + i + 1]
				modprod *= mod[k + i + 1]
			end
			sfc -= modprod
			k += 4
		end
		partOff = k
		scfsi = -16
	end
	readScalefactors(iscf, ist, scfSize, partRow, partOff, bs, scfsi)
	if gr.n_short_sfb ~= 0 then
		local sh = 3 - scfShift
		local nl = gr.n_long_sfb
		for i = 0, gr.n_short_sfb - 1, 3 do
			iscf[nl + i + 1] = band(iscf[nl + i + 1] + lsh(gr.subblock_gain[1], sh), 255)
			iscf[nl + i + 2] = band(iscf[nl + i + 2] + lsh(gr.subblock_gain[2], sh), 255)
			iscf[nl + i + 3] = band(iscf[nl + i + 3] + lsh(gr.subblock_gain[3], sh), 255)
		end
	elseif gr.preflag ~= 0 then
		local preamp = T.g_preamp
		for i = 0, 9 do
			iscf[11 + i + 1] = band(iscf[11 + i + 1] + preamp[i + 1], 255)
		end
	end
	local gainExp = gr.global_gain + BITS_DEQUANTIZER_OUT * 4 - 210 - (isMsStereo(h) and 2 or 0)
	local gain = ldexpQ2(2048, MAX_SCFI - gainExp)
	for i = 1, gr.n_long_sfb + gr.n_short_sfb do
		scf[i] = ldexpQ2(gain, lsh(iscf[i], scfShift))
	end
end

local function L3pow43(x)
	if x < 129 then
		return pow43[16 + x + 1]
	end
	local mult = 256
	if x < 1024 then
		mult = 16
		x = lsh(x, 3)
	end
	local sign = band(2 * x, 64)
	local frac = (band(x, 63) - sign) / (band(x, bnot(63)) + sign)
	return pow43[16 + rsh(x + sign, 6) + 1] * (1 + frac * ((4 / 3) + frac * (2 / 9))) * mult
end

-- Huffman -----------------------------------------------------------------------------------
local function huffman(dst, dstOff, bs, gr, scf, limitBits)
	local buf, base = bs.buf, bs.base
	local one = 0
	local ireg = 0
	local bigValCnt = gr.big_values
	local sfb = gr.sfbtab
	local sfbi = 1
	local scfi = 1
	local p = base + rsh(bs.pos, 3)
	local cache = lsh(((readu8(buf, p) * 256 + readu8(buf, p + 1)) * 256 + readu8(buf, p + 2)) * 256 + readu8(buf, p + 3), band(bs.pos, 7))
	local sh = band(bs.pos, 7) - 8
	p += 4
	local d = dstOff
	while bigValCnt > 0 do
		local tabNum = gr.table_select[ireg + 1]
		local sfbCnt = gr.region_count[ireg + 1]
		ireg += 1
		local cbOff = tabindex[tabNum + 1] + 1
		local linbits = linbitsT[tabNum + 1]
		while true do
			local np = sfb[sfbi] // 2
			sfbi += 1
			local pairs = min(bigValCnt, np)
			one = scf[scfi]
			scfi += 1
			repeat
				local w = 5
				local leaf = tabs[cbOff + rsh(cache, 27)]
				while leaf < 0 do
					cache = lsh(cache, w)
					sh += w
					w = band(leaf, 7)
					leaf = tabs[cbOff + rsh(cache, 32 - w) - (leaf // 8)]
				end
				local fl = rsh(leaf, 8)
				cache = lsh(cache, fl)
				sh += fl
				for _ = 1, 2 do
					local lsb = band(leaf, 15)
					if lsb == 15 and linbits ~= 0 then
						lsb += rsh(cache, 32 - linbits)
						cache = lsh(cache, linbits)
						sh += linbits
						while sh >= 0 do
							cache = bor(cache, lsh(readu8(buf, p), sh))
							p += 1
							sh -= 8
						end
						dst[d + 1] = one * L3pow43(lsb) * (btest(cache, 0x80000000) and -1 or 1)
					else
						dst[d + 1] = pow43[16 + lsb - 16 * rsh(cache, 31) + 1] * one
					end
					if lsb ~= 0 then
						cache = lsh(cache, 1)
						sh += 1
					end
					d += 1
					leaf = rsh(leaf, 4)
				end
				while sh >= 0 do
					cache = bor(cache, lsh(readu8(buf, p), sh))
					p += 1
					sh -= 8
				end
				pairs -= 1
			until pairs <= 0
			bigValCnt -= np
			if bigValCnt <= 0 then
				break
			end
			sfbCnt -= 1
			if sfbCnt < 0 then
				break
			end
		end
	end

	local np = 1 - bigValCnt
	local cb1 = (gr.count1_table ~= 0) and tab33 or tab32
	while true do
		local leaf = cb1[rsh(cache, 28) + 1]
		if not btest(leaf, 8) then
			local nb = band(leaf, 3)
			leaf = cb1[rsh(leaf, 3) + ((nb > 0) and rsh(lsh(cache, 4), 32 - nb) or 0) + 1]
		end
		local fl = band(leaf, 7)
		cache = lsh(cache, fl)
		sh += fl
		if (p - base) * 8 - 24 + sh > limitBits then
			break
		end
		np -= 1
		if np == 0 then
			np = (sfb[sfbi] or 0) // 2
			sfbi += 1
			if np == 0 then
				break
			end
			one = scf[scfi]
			scfi += 1
		end
		if btest(leaf, 128) then
			dst[d + 1] = btest(cache, 0x80000000) and -one or one
			cache = lsh(cache, 1)
			sh += 1
		end
		if btest(leaf, 64) then
			dst[d + 2] = btest(cache, 0x80000000) and -one or one
			cache = lsh(cache, 1)
			sh += 1
		end
		np -= 1
		if np == 0 then
			np = (sfb[sfbi] or 0) // 2
			sfbi += 1
			if np == 0 then
				break
			end
			one = scf[scfi]
			scfi += 1
		end
		if btest(leaf, 32) then
			dst[d + 3] = btest(cache, 0x80000000) and -one or one
			cache = lsh(cache, 1)
			sh += 1
		end
		if btest(leaf, 16) then
			dst[d + 4] = btest(cache, 0x80000000) and -one or one
			cache = lsh(cache, 1)
			sh += 1
		end
		while sh >= 0 do
			cache = bor(cache, lsh(readu8(buf, p), sh))
			p += 1
			sh -= 8
		end
		d += 4
	end
	bs.pos = limitBits
end

-- stereo ------------------------------------------------------------------------------------
local function midside(g, lo, n)
	for i = lo + 1, lo + n do
		local a, b = g[i], g[i + 576]
		g[i] = a + b
		g[i + 576] = a - b
	end
end

local function intensityBand(g, lo, n, kl, kr)
	for i = lo + 1, lo + n do
		g[i + 576] = g[i] * kr
		g[i] *= kl
	end
end

local function stereoTopBand(g, rightOff, sfb, nbands, maxBand)
	maxBand[1], maxBand[2], maxBand[3] = -1, -1, -1
	local r = rightOff
	for i = 0, nbands - 1 do
		local w = sfb[i + 1]
		for k = 0, w - 1, 2 do
			if g[r + k + 1] ~= 0 or g[r + k + 2] ~= 0 then
				maxBand[i % 3 + 1] = i
				break
			end
		end
		r += w
	end
end

local gPan = T.g_pan
local function stereoProcess(g, ist, sfb, h, maxBand, mpeg2sh)
	local mpeg1 = isMpeg1(h)
	local maxPos = mpeg1 and 7 or 64
	local ms = testMsStereo(h)
	local lo = 0
	local i = 0
	while sfb[i + 1] ~= 0 do
		local w = sfb[i + 1]
		local ipos = ist[i + 1]
		if i > maxBand[i % 3 + 1] and ipos < maxPos then
			local s = ms and 1.41421356 or 1
			local kl, kr
			if mpeg1 then
				kl, kr = gPan[2 * ipos + 1], gPan[2 * ipos + 2]
			else
				kl = 1
				kr = ldexpQ2(1, lsh(rsh(ipos + 1, 1), mpeg2sh))
				if band(ipos, 1) ~= 0 then
					kl, kr = kr, 1
				end
			end
			intensityBand(g, lo, w, kl * s, kr * s)
		elseif ms then
			midside(g, lo, w)
		end
		lo += w
		i += 1
	end
end

local function intensityStereo(g, ist, gr0, gr1, h, maxBand)
	local nSfb = gr0.n_long_sfb + gr0.n_short_sfb
	local maxBlocks = (gr0.n_short_sfb ~= 0) and 3 or 1
	stereoTopBand(g, 576, gr0.sfbtab, nSfb, maxBand)
	if gr0.n_long_sfb ~= 0 then
		local m = max(maxBand[1], maxBand[2], maxBand[3])
		maxBand[1], maxBand[2], maxBand[3] = m, m, m
	end
	local defaultPos = isMpeg1(h) and 3 or 0
	for i = 0, maxBlocks - 1 do
		local itop = nSfb - maxBlocks + i
		local prev = itop - maxBlocks
		ist[itop + 1] = (maxBand[i + 1] >= prev) and defaultPos or ist[prev + 1]
	end
	stereoProcess(g, ist, gr0.sfbtab, h, maxBand, band(gr1.scalefac_compress, 1))
end

-- reorder / antialias / imdct ---------------------------------------------------------------
local function reorder(g, off, scratch, sfb, si)
	local src, n = off, 0
	while (sfb[si] or 0) ~= 0 do
		local len = sfb[si]
		for _ = 1, len do
			scratch[n + 1] = g[src + 1]
			scratch[n + 2] = g[src + len + 1]
			scratch[n + 3] = g[src + 2 * len + 1]
			n += 3
			src += 1
		end
		src += 2 * len
		si += 3
	end
	for i = 1, n do
		g[off + i] = scratch[i]
	end
end

local aa0, aa1 = T.g_aa[1], T.g_aa[2]
local function antialias(g, off, nbands)
	for b = 0, nbands - 1 do
		local base = off + b * 18
		for i = 0, 7 do
			local u, d = g[base + 19 + i], g[base + 18 - i]
			g[base + 19 + i] = u * aa0[i + 1] - d * aa1[i + 1]
			g[base + 18 - i] = u * aa1[i + 1] + d * aa0[i + 1]
		end
	end
end

local function dct3_9(y)
	local s0, s2, s4, s6, s8 = y[1], y[3], y[5], y[7], y[9]
	local t0 = s0 + s6 * 0.5
	s0 -= s6
	local t4 = (s4 + s2) * 0.93969262
	local t2 = (s8 + s2) * 0.76604444
	s6 = (s4 - s8) * 0.17364818
	s4 += s8 - s2
	s2 = s0 - s4 * 0.5
	y[5] = s4 + s0
	s8 = t0 - t2 + s6
	s0 = t0 - t4 + t2
	s4 = t0 + t4 - s6
	local s1, s3, s5, s7 = y[2], y[4], y[6], y[8]
	s3 *= 0.86602540
	t0 = (s5 + s1) * 0.98480775
	t4 = (s5 - s7) * 0.34202014
	t2 = (s1 + s7) * 0.64278761
	s1 = (s1 - s5 - s7) * 0.86602540
	s5 = t0 - s3 - t2
	s7 = t4 - s3 - t0
	s3 = t4 + s3 - t2
	y[1] = s4 - s7
	y[2] = s2 + s1
	y[3] = s0 - s3
	y[4] = s8 + s5
	y[6] = s8 - s5
	y[7] = s0 + s3
	y[8] = s2 - s1
	y[9] = s4 + s7
end

local tw9 = T.g_twid9
local co9, si9 = table.create(9, 0), table.create(9, 0)
local function imdct36(g, goff, ov, ooff, window, nbands)
	local co, si = co9, si9
	for j = 0, nbands - 1 do
		local gb = goff + j * 18
		local ob = ooff + j * 9
		co[1] = -g[gb + 1]
		si[1] = g[gb + 18]
		for i = 0, 3 do
			local a, b, c, d = g[gb + 4 * i + 2], g[gb + 4 * i + 3], g[gb + 4 * i + 4], g[gb + 4 * i + 5]
			si[9 - 2 * i] = a - b
			co[2 + 2 * i] = a + b
			si[8 - 2 * i] = d - c
			co[3 + 2 * i] = -(c + d)
		end
		dct3_9(co)
		dct3_9(si)
		si[2], si[4], si[6], si[8] = -si[2], -si[4], -si[6], -si[8]
		for i = 1, 9 do
			local ovl = ov[ob + i]
			local sum = co[i] * tw9[9 + i] + si[i] * tw9[i]
			ov[ob + i] = co[i] * tw9[i] - si[i] * tw9[9 + i]
			g[gb + i] = ovl * window[i] - sum * window[9 + i]
			g[gb + 19 - i] = ovl * window[9 + i] + sum * window[i]
		end
	end
end

local tw3 = T.g_twid3
local function imdct12(x, xo, dst, doff, ov, ooff)
	-- idct3(-x0, x6 + x3, x12 + x9) and idct3(x15, x12 - x9, x6 - x3)
	local x0, x3, x6, x9, x12, x15 = x[xo + 1], x[xo + 4], x[xo + 7], x[xo + 10], x[xo + 13], x[xo + 16]
	local function idct3(a0, a1, a2)
		local m1 = a1 * 0.86602540
		local a = a0 - a2 * 0.5
		return a + m1, a0 + a2, a - m1
	end
	local c0, c1, c2 = idct3(-x0, x6 + x3, x12 + x9)
	local s0, s1, s2 = idct3(x15, x12 - x9, x6 - x3)
	s1 = -s1
	local co = { c0, c1, c2 }
	local si = { s0, s1, s2 }
	for i = 0, 2 do
		local ovl = ov[ooff + i + 1]
		local sum = co[i + 1] * tw3[4 + i] + si[i + 1] * tw3[1 + i]
		ov[ooff + i + 1] = co[i + 1] * tw3[1 + i] - si[i + 1] * tw3[4 + i]
		dst[doff + i + 1] = ovl * tw3[3 - i] - sum * tw3[6 - i]
		dst[doff + 6 - i] = ovl * tw3[6 - i] + sum * tw3[3 - i]
	end
end

local tmp18 = table.create(18, 0)
local function imdctShort(g, goff, ov, ooff, nbands)
	for b = 0, nbands - 1 do
		local gb, ob = goff + b * 18, ooff + b * 9
		for i = 1, 18 do
			tmp18[i] = g[gb + i]
		end
		for i = 1, 6 do
			g[gb + i] = ov[ob + i]
		end
		imdct12(tmp18, 0, g, gb + 6, ov, ob + 6)
		imdct12(tmp18, 1, g, gb + 12, ov, ob + 6)
		imdct12(tmp18, 2, ov, ob, ov, ob + 6)
	end
end

local function changeSign(g, off)
	for b = 0, 30, 2 do
		local base = off + 18 + b * 18
		for i = 1, 17, 2 do
			g[base + i + 1] = -g[base + i + 1]
		end
	end
end

local mdctWin0, mdctWin1 = T.g_mdct_window[1], T.g_mdct_window[2]
local function imdctGr(g, goff, ov, ooff, blockType, nLong)
	if nLong > 0 then
		imdct36(g, goff, ov, ooff, mdctWin0, nLong)
		goff += 18 * nLong
		ooff += 9 * nLong
	end
	if blockType == SHORT_BLOCK_TYPE then
		imdctShort(g, goff, ov, ooff, 32 - nLong)
	else
		imdct36(g, goff, ov, ooff, (blockType == STOP_BLOCK_TYPE) and mdctWin1 or mdctWin0, 32 - nLong)
	end
end

-- synthesis ---------------------------------------------------------------------------------
local sec = T.g_sec
local tDct = table.create(32, 0)
local function dctII(g, off, n)
	local t = tDct
	for k = 0, n - 1 do
		local y = off + k
		for i = 0, 7 do
			local x0 = g[y + i * 18 + 1]
			local x1 = g[y + (15 - i) * 18 + 1]
			local x2 = g[y + (16 + i) * 18 + 1]
			local x3 = g[y + (31 - i) * 18 + 1]
			local t0, t1 = x0 + x3, x1 + x2
			local t2 = (x1 - x2) * sec[3 * i + 1]
			local t3 = (x0 - x3) * sec[3 * i + 2]
			t[i + 1] = t0 + t1
			t[9 + i] = (t0 - t1) * sec[3 * i + 3]
			t[17 + i] = t3 + t2
			t[25 + i] = (t3 - t2) * sec[3 * i + 3]
		end
		for r = 0, 3 do
			local o = r * 8
			local x0, x1, x2, x3, x4, x5, x6, x7 = t[o + 1], t[o + 2], t[o + 3], t[o + 4], t[o + 5], t[o + 6], t[o + 7], t[o + 8]
			local xt = x0 - x7
			x0 += x7
			x7 = x1 - x6
			x1 += x6
			x6 = x2 - x5
			x2 += x5
			x5 = x3 - x4
			x3 += x4
			x4 = x0 - x3
			x0 += x3
			x3 = x1 - x2
			x1 += x2
			t[o + 1] = x0 + x1
			t[o + 5] = (x0 - x1) * 0.70710677
			x5 = x5 + x6
			x6 = (x6 + x7) * 0.70710677
			x7 = x7 + xt
			x3 = (x3 + x4) * 0.70710677
			x5 -= x7 * 0.198912367
			x7 += x5 * 0.382683432
			x5 -= x7 * 0.198912367
			x0 = xt - x6
			xt += x6
			t[o + 2] = (xt + x7) * 0.50979561
			t[o + 3] = (x4 + x3) * 0.54119611
			t[o + 4] = (x0 - x5) * 0.60134488
			t[o + 6] = (x0 + x5) * 0.89997619
			t[o + 7] = (x4 - x3) * 1.30656302
			t[o + 8] = (xt - x7) * 2.56291556
		end
		local yy = y
		for i = 0, 6 do
			g[yy + 1] = t[i + 1]
			g[yy + 19] = t[17 + i] + t[25 + i] + t[26 + i]
			g[yy + 37] = t[9 + i] + t[10 + i]
			g[yy + 55] = t[18 + i] + t[25 + i] + t[26 + i]
			yy += 72
		end
		g[yy + 1] = t[8]
		g[yy + 19] = t[24] + t[32]
		g[yy + 37] = t[16]
		g[yy + 55] = t[32]
	end
end

local function synthPair(pcm, idx, nch, z, zo)
	local a = (z[zo + 14 * 64 + 1] - z[zo + 1]) * 29
	a += (z[zo + 64 + 1] + z[zo + 13 * 64 + 1]) * 213
	a += (z[zo + 12 * 64 + 1] - z[zo + 2 * 64 + 1]) * 459
	a += (z[zo + 3 * 64 + 1] + z[zo + 11 * 64 + 1]) * 2037
	a += (z[zo + 10 * 64 + 1] - z[zo + 4 * 64 + 1]) * 5153
	a += (z[zo + 5 * 64 + 1] + z[zo + 9 * 64 + 1]) * 6574
	a += (z[zo + 8 * 64 + 1] - z[zo + 6 * 64 + 1]) * 37489
	a += z[zo + 7 * 64 + 1] * 75038
	pcm[idx + 1] = a
	zo += 2
	a = z[zo + 14 * 64 + 1] * 104
	a += z[zo + 12 * 64 + 1] * 1567
	a += z[zo + 10 * 64 + 1] * 9727
	a += z[zo + 8 * 64 + 1] * 64019
	a += z[zo + 6 * 64 + 1] * -9975
	a += z[zo + 4 * 64 + 1] * -45
	a += z[zo + 2 * 64 + 1] * 146
	a += z[zo + 1] * -5
	pcm[idx + 16 * nch + 1] = a
end

local win = T.g_win
local function synth(g, xl, pcm, pcmOff, nch, lins, lo)
	local xr = xl + 576 * (nch - 1)
	local dstl, dstr = pcmOff, pcmOff + (nch - 1)
	local zl = lo + 15 * 64 -- zlin, 0-based offset into lins
	lins[zl + 4 * 15 + 1] = g[xl + 18 * 16 + 1]
	lins[zl + 4 * 15 + 2] = g[xr + 18 * 16 + 1]
	lins[zl + 4 * 15 + 3] = g[xl + 1]
	lins[zl + 4 * 15 + 4] = g[xr + 1]
	lins[zl + 4 * 31 + 1] = g[xl + 1 + 18 * 16 + 1]
	lins[zl + 4 * 31 + 2] = g[xr + 1 + 18 * 16 + 1]
	lins[zl + 4 * 31 + 3] = g[xl + 2]
	lins[zl + 4 * 31 + 4] = g[xr + 2]
	synthPair(pcm, dstr, nch, lins, lo + 4 * 15 + 1)
	synthPair(pcm, dstr + 32 * nch, nch, lins, lo + 4 * 15 + 64 + 1)
	synthPair(pcm, dstl, nch, lins, lo + 4 * 15)
	synthPair(pcm, dstl + 32 * nch, nch, lins, lo + 4 * 15 + 64)
	local wi = 1
	for i = 14, 0, -1 do
		lins[zl + 4 * i + 1] = g[xl + 18 * (31 - i) + 1]
		lins[zl + 4 * i + 2] = g[xr + 18 * (31 - i) + 1]
		lins[zl + 4 * i + 3] = g[xl + 1 + 18 * (31 - i) + 1]
		lins[zl + 4 * i + 4] = g[xr + 1 + 18 * (31 - i) + 1]
		lins[zl + 4 * (i + 16) + 1] = g[xl + 1 + 18 * (1 + i) + 1]
		lins[zl + 4 * (i + 16) + 2] = g[xr + 1 + 18 * (1 + i) + 1]
		lins[zl + 4 * (i - 16) + 3] = g[xl + 18 * (1 + i) + 1]
		lins[zl + 4 * (i - 16) + 4] = g[xr + 18 * (1 + i) + 1]
		local a0, a1, a2, a3, b0, b1, b2, b3 = 0, 0, 0, 0, 0, 0, 0, 0
		for k = 0, 7 do
			local w0, w1 = win[wi], win[wi + 1]
			wi += 2
			local vz = zl + 4 * i - k * 64 + 1
			local vy = zl + 4 * i - (15 - k) * 64 + 1
			local z0, z1, z2, z3 = lins[vz], lins[vz + 1], lins[vz + 2], lins[vz + 3]
			local y0, y1, y2, y3 = lins[vy], lins[vy + 1], lins[vy + 2], lins[vy + 3]
			b0 += z0 * w1 + y0 * w0
			b1 += z1 * w1 + y1 * w0
			b2 += z2 * w1 + y2 * w0
			b3 += z3 * w1 + y3 * w0
			if k % 2 == 1 then
				a0 += y0 * w1 - z0 * w0
				a1 += y1 * w1 - z1 * w0
				a2 += y2 * w1 - z2 * w0
				a3 += y3 * w1 - z3 * w0
			else
				a0 += z0 * w0 - y0 * w1
				a1 += z1 * w0 - y1 * w1
				a2 += z2 * w0 - y2 * w1
				a3 += z3 * w0 - y3 * w1
			end
		end
		pcm[dstr + (15 - i) * nch + 1] = a1
		pcm[dstr + (17 + i) * nch + 1] = b1
		pcm[dstl + (15 - i) * nch + 1] = a0
		pcm[dstl + (17 + i) * nch + 1] = b0
		pcm[dstr + (47 - i) * nch + 1] = a3
		pcm[dstr + (49 + i) * nch + 1] = b3
		pcm[dstl + (47 - i) * nch + 1] = a2
		pcm[dstl + (49 + i) * nch + 1] = b2
	end
end

local function synthGranule(qmf, g, nbands, nch, pcm, pcmOff, lins)
	for ch = 0, nch - 1 do
		dctII(g, 576 * ch, nbands)
	end
	for i = 1, 960 do
		lins[i] = qmf[i]
	end
	for i = 0, nbands - 1, 2 do
		synth(g, i, pcm, pcmOff + 32 * nch * i, nch, lins, i * 64)
	end
	local o = nbands * 64
	if nch == 1 then
		for i = 1, 960, 2 do
			qmf[i] = lins[o + i]
		end
	else
		for i = 1, 960 do
			qmf[i] = lins[o + i]
		end
	end
end

-- Layer I / II --------------------------------------------------------------------------------
-- bit allocation codes per subband group ({ table offset, code width, bands })
local L12_BA_CODES = {
	0, 17, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
	0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
	0, 17, 18, 3, 19, 4, 5, 16,
	0, 17, 18, 16,
	0, 17, 18, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
	0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
}
local L12_DEQ = {}
do
	local den = { 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, 3, 5, 9 }
	for i, x in ipairs(den) do
		L12_DEQ[3 * i - 2] = 9.53674316e-07 / x
		L12_DEQ[3 * i - 1] = 7.56931807e-07 / x
		L12_DEQ[3 * i] = 6.00777173e-07 / x
	end
end
local ALLOC_L1 = { { 76, 4, 32 } }
local ALLOC_L2M2 = { { 60, 4, 4 }, { 44, 3, 7 }, { 44, 2, 19 } }
local ALLOC_L2M1 = { { 0, 4, 3 }, { 16, 4, 8 }, { 32, 3, 12 }, { 40, 2, 7 } }
local ALLOC_L2M1_LOW = { { 44, 4, 2 }, { 44, 3, 10 } }

local function l12ScaleInfo(h, bs, sci)
	local mode = rsh(h[4], 6)
	local stereoBands = 32
	if mode == 3 then
		stereoBands = 0
	elseif mode == 1 then
		stereoBands = band(rsh(h[4], 4), 3) * 4 + 4
	end
	local alloc, nbands
	if isLayer1(h) then
		alloc, nbands = ALLOC_L1, 32
	elseif not isMpeg1(h) then
		alloc, nbands = ALLOC_L2M2, 30
	else
		local kbps = rsh(bitrateKbps(h), mode ~= 3 and 1 or 0)
		if kbps == 0 then
			kbps = 192
		end
		alloc, nbands = ALLOC_L2M1, 27
		if kbps < 56 then
			alloc, nbands = ALLOC_L2M1_LOW, getSampleRate(h) == 2 and 12 or 8
		elseif kbps >= 96 and getSampleRate(h) ~= 1 then
			nbands = 30
		end
	end
	stereoBands = min(stereoBands, nbands)
	sci.total, sci.stereo = nbands, stereoBands
	local ba, scfcod, scf = sci.bitalloc, sci.scfcod, sci.scf
	local k, bits, off, ai = 0, 0, 0, 0
	for i = 0, nbands - 1 do
		if i == k then
			ai += 1
			local a = alloc[ai]
			k += a[3]
			bits, off = a[2], a[1]
		end
		local v = L12_BA_CODES[off + getBits(bs, bits) + 1]
		ba[2 * i + 1] = v
		if i < stereoBands then
			v = L12_BA_CODES[off + getBits(bs, bits) + 1]
		end
		ba[2 * i + 2] = stereoBands > 0 and v or 0
	end
	local layer1 = isLayer1(h)
	for i = 1, 2 * nbands do
		if ba[i] ~= 0 then
			scfcod[i] = layer1 and 2 or getBits(bs, 2)
		else
			scfcod[i] = 6
		end
	end
	local si = 1
	for i = 1, 2 * nbands do
		local s = 0
		local b = ba[i]
		local mask = b ~= 0 and (4 + band(rsh(19, scfcod[i]), 3)) or 0
		local m = 4
		while m > 0 do
			if band(mask, m) ~= 0 then
				local v = getBits(bs, 6)
				s = L12_DEQ[b * 3 - 6 + v % 3 + 1] * rsh(2097152, v // 3)
			end
			scf[si] = s
			si += 1
			m = rsh(m, 1)
		end
	end
	for i = stereoBands, nbands - 1 do
		ba[2 * i + 2] = 0
	end
end

-- one group of samples per subband (4 x groupSize each) into g from goff (0-based): channel 1 at +576
local function l12Dequantize(g, goff, bs, sci, groupSize)
	local choff = 576
	local ba = sci.bitalloc
	for j = 0, 3 do
		local dst = goff + groupSize * j
		for i = 1, 2 * sci.total do
			local b = ba[i]
			if b ~= 0 then
				if b < 17 then
					local half = lsh(1, b - 1) - 1
					for k = 0, groupSize - 1 do
						g[dst + k + 1] = getBits(bs, b) - half
					end
				else
					local mod = lsh(2, b - 17) + 1
					local code = getBits(bs, mod + 2 - rsh(mod, 3))
					for k = 0, groupSize - 1 do
						g[dst + k + 1] = code % mod - mod // 2
						code = code // mod
					end
				end
			end
			dst += choff
			choff = 18 - choff
		end
	end
	return groupSize * 4
end

local function l12ApplyScf(sci, scfOff, g)
	for k = sci.stereo * 18 + 1, sci.total * 18 do
		g[576 + k] = g[k]
	end
	local scf = sci.scf
	local dst, s = 0, scfOff
	for _ = 1, sci.total do
		local s0, s1 = scf[s + 1], scf[s + 4]
		for k = 1, 12 do
			g[dst + k] *= s0
			g[dst + 576 + k] *= s1
		end
		dst += 18
		s += 6
	end
end

-- frames ------------------------------------------------------------------------------------
local function matchFrame(b, o, bytes, fb)
	local h = hdrAt(b, o)
	local i = 0
	for nmatch = 0, MAX_FRAME_SYNC_MATCHES - 1 do
		local hi = hdrAt(b, o + i)
		i += frameBytes(hi, fb) + hdrPadding(hi)
		if i + 4 > bytes then
			return nmatch > 0
		end
		if not hdrCompare(h, b, o + i) then
			return false
		end
	end
	return true
end

-- returns offset (relative), frame size incl. padding (0 if none), free format bytes
local function findFrame(b, o, bytes, freeFormatBytes)
	for i = 0, bytes - 5 do
		if hdrValidAt(b, o + i) then
			local h = hdrAt(b, o + i)
			local fb = frameBytes(h, freeFormatBytes)
			local fap = fb + hdrPadding(h)
			local k = 4
			while fb == 0 and k < MAX_FREE_FORMAT_FRAME_SIZE and i + 2 * k < bytes - 4 do
				if hdrCompare(h, b, o + i + k) then
					local f = k - hdrPadding(h)
					local nextfb = f + hdrPadding(hdrAt(b, o + i + k))
					if not (i + k + nextfb + 4 > bytes or not hdrCompare(h, b, o + i + k + nextfb)) then
						fap = k
						fb = f
						freeFormatBytes = f
					end
				end
				k += 1
			end
			if (fb ~= 0 and i + fap <= bytes and matchFrame(b, o + i, bytes - i, fb)) or (i == 0 and fap == bytes) then
				return i, fap, freeFormatBytes
			end
			freeFormatBytes = 0
		end
	end
	return bytes, 0, freeFormatBytes
end

local function newDecoder()
	local d = {
		overlap = { table.create(288, 0), table.create(288, 0) },
		qmf = table.create(960, 0),
		reserv = 0,
		reservBuf = buffer.create(MAX_BITRESERVOIR_BYTES),
		header = { 0, 0, 0, 0 },
		freeFormatBytes = 0,
		maindata = buffer.create(MAX_BITRESERVOIR_BYTES + MAX_FREE_FORMAT_FRAME_SIZE + 16),
		grs = { newGranule(), newGranule(), newGranule(), newGranule() },
		grbuf = table.create(1152 + 64, 0),
		scf = table.create(40, 0),
		iscf = table.create(40, 0),
		scfSize = table.create(4, 0),
		syn = table.create(33 * 64, 0),
		ist = { table.create(39, 0), table.create(39, 0) },
		maxBand = table.create(3, 0),
		mbs = { buf = nil, base = 0, pos = 0, limit = 0 },
		sci = { bitalloc = table.create(64, 0), scfcod = table.create(64, 0), scf = table.create(192, 0), total = 0, stereo = 0 },
	}
	return d
end

local function resetDecoder(d)
	for c = 1, 2 do
		table.clear(d.overlap[c])
		for i = 1, 288 do
			d.overlap[c][i] = 0
		end
	end
	for i = 1, 960 do
		d.qmf[i] = 0
	end
	d.reserv = 0
	d.freeFormatBytes = 0
	d.header[1] = 0
end

local function saveReservoir(d, mbs)
	local pos = (mbs.pos + 7) // 8
	local remains = mbs.limit // 8 - pos
	if remains > MAX_BITRESERVOIR_BYTES then
		pos += remains - MAX_BITRESERVOIR_BYTES
		remains = MAX_BITRESERVOIR_BYTES
	end
	if remains > 0 then
		buffer.copy(d.reservBuf, 0, d.maindata, pos, remains)
	end
	d.reserv = max(remains, 0)
end

local function restoreReservoir(d, bs, mainDataBegin)
	local fbytes = (bs.limit - bs.pos) // 8
	local have = min(d.reserv, mainDataBegin)
	if have > 0 then
		buffer.copy(d.maindata, 0, d.reservBuf, max(0, d.reserv - mainDataBegin), have)
	end
	if fbytes > 0 then
		buffer.copy(d.maindata, have, bs.buf, bs.base + bs.pos // 8, fbytes)
	end
	-- zero a few bytes past the end (the Huffman reader looks ahead)
	buffer.fill(d.maindata, have + max(fbytes, 0), 0, min(8, buffer.len(d.maindata) - have - max(fbytes, 0)))
	local mbs = d.mbs
	mbs.buf, mbs.base, mbs.pos, mbs.limit = d.maindata, 0, 0, (have + fbytes) * 8
	return d.reserv >= mainDataBegin
end

local function decodeGranule(d, h, grBase, nch)
	local g, mbs = d.grbuf, d.mbs
	for ch = 0, nch - 1 do
		local gr = d.grs[grBase + ch]
		local limit = mbs.pos + gr.part_23_length
		decodeScalefactors(h, d.ist[ch + 1], mbs, gr, d.scf, ch, d.iscf, d.scfSize)
		huffman(g, ch * 576, mbs, gr, d.scf, limit)
	end
	if testIStereo(h) then
		intensityStereo(g, d.ist[2], d.grs[grBase], d.grs[grBase + 1], h, d.maxBand)
	elseif isMsStereo(h) then
		midside(g, 0, 576)
	end
	for ch = 0, nch - 1 do
		local gr = d.grs[grBase + ch]
		local aaBands = 31
		local nLong = lsh((gr.mixed_block_flag ~= 0) and 2 or 0, (getMySampleRate(h) == 2) and 1 or 0)
		if gr.n_short_sfb ~= 0 then
			aaBands = nLong - 1
			reorder(g, ch * 576 + nLong * 18, d.syn, gr.sfbtab, gr.n_long_sfb + 1)
		end
		antialias(g, ch * 576, aaBands)
		imdctGr(g, ch * 576, d.overlap[ch + 1], 0, gr.block_type, nLong)
		changeSign(g, ch * 576)
	end
end

-- Decodes one frame at byte offset o (bytes available: n). Returns samplesPerChannel (0 if the frame
-- couldn't be decoded), bytesConsumed, channels, hz. pcm receives interleaved samples (int16 scale).
local hdrScratch = { 0, 0, 0, 0 }
local function decodeFrame(d, b, o, n, pcm)
	local i, frameSize = 0, 0
	local dh = d.header
	if n > 4 and dh[1] == 0xFF and hdrCompare(dh, b, o) then
		local h = hdrAt(b, o, hdrScratch)
		frameSize = frameBytes(h, d.freeFormatBytes) + hdrPadding(h)
		if frameSize ~= n and (frameSize + 4 > n or not hdrCompare(h, b, o + frameSize)) then
			frameSize = 0
		end
	end
	if frameSize == 0 then
		resetDecoder(d)
		local ff
		i, frameSize, ff = findFrame(b, o, n, d.freeFormatBytes)
		d.freeFormatBytes = ff
		if frameSize == 0 or i + frameSize > n then
			return 0, i, 0, 0
		end
	end
	local h = hdrAt(b, o + i, dh)
	local nch = isMono(h) and 1 or 2
	local hz = sampleRateHz(h)
	local layer = 4 - getLayer(h)
	local bs = { buf = b, base = o + i + 4, pos = 0, limit = (frameSize - 4) * 8 }
	if isCrc(h) then
		getBits(bs, 16)
	end
	if layer ~= 3 then
		-- Layer I (384 samples) / II (1152): three runs of 12 samples per subband (Layer I: one)
		local sci = d.sci
		l12ScaleInfo(h, bs, sci)
		local g = d.grbuf
		for k = 1, 1152 do
			g[k] = 0
		end
		local filled, pcmOff = 0, 0
		local groupSize = layer == 1 and 1 or 3
		for igr = 0, 2 do
			filled += l12Dequantize(g, filled, bs, sci, groupSize)
			if filled == 12 then
				filled = 0
				l12ApplyScf(sci, igr, g)
				synthGranule(d.qmf, g, 12, nch, pcm, pcmOff, d.syn)
				for k = 1, 1152 do
					g[k] = 0
				end
				pcmOff += 384 * nch
			end
			if bs.pos > bs.limit then
				resetDecoder(d)
				return 0, i + frameSize, nch, hz
			end
		end
		return frameSamples(h), i + frameSize, nch, hz
	end
	local mainDataBegin = readSideInfo(bs, d.grs, h)
	if mainDataBegin < 0 or bs.pos > bs.limit then
		d.header[1] = 0
		return 0, i + frameSize, nch, hz
	end
	local ok = restoreReservoir(d, bs, mainDataBegin)
	local granules = isMpeg1(h) and 2 or 1
	if ok then
		local g = d.grbuf
		for igr = 0, granules - 1 do
			for k = 1, 1152 do
				g[k] = 0
			end
			decodeGranule(d, h, igr * nch + 1, nch)
			synthGranule(d.qmf, g, 18, nch, pcm, igr * 576 * nch, d.syn)
		end
	end
	saveReservoir(d, d.mbs)
	return ok and frameSamples(h) or 0, i + frameSize, nch, hz
end

-- Xing / Info / LAME --------------------------------------------------------------------------
local function checkVbrTag(b, o, frameSize)
	if frameSize < 12 then
		return 0
	end
	local h = hdrAt(b, o)
	local bs = { buf = b, base = o + 4, pos = 0, limit = (frameSize - 4) * 8 }
	if isCrc(h) then
		getBits(bs, 16)
	end
	local grs = { newGranule(), newGranule(), newGranule(), newGranule() }
	if readSideInfo(bs, grs, h) < 0 then
		return 0
	end
	local tagOff = 4 + bs.pos // 8
	if tagOff > frameSize or frameSize - tagOff < 8 then
		return 0
	end
	local t = o + tagOff
	local tag = buffer.readstring(b, t, 4)
	if tag ~= "Xing" and tag ~= "Info" then
		return 0
	end
	local flags = readu8(b, t + 7)
	if not btest(flags, 1) then
		return -1
	end
	tagOff += 8
	if frameSize - tagOff < 4 then
		return 0
	end
	t = o + tagOff
	local frames = ((readu8(b, t) * 256 + readu8(b, t + 1)) * 256 + readu8(b, t + 2)) * 256 + readu8(b, t + 3)
	tagOff += 4
	if btest(flags, 2) then
		tagOff += 4
	end
	if btest(flags, 4) then
		tagOff += 100
	end
	if btest(flags, 8) then
		tagOff += 4
	end
	if frameSize - tagOff < 1 then
		return 0
	end
	local delay, padding = 0, 0
	if readu8(b, o + tagOff) ~= 0 then
		if frameSize - tagOff <= 35 then
			return 0
		end
		t = o + tagOff + 21
		local t0, t1, t2 = readu8(b, t), readu8(b, t + 1), readu8(b, t + 2)
		delay = (t0 * 16 + rsh(t1, 4)) + 529
		padding = (band(t1, 15) * 256 + t2) - 529
	end
	return 1, frames, delay, padding
end

-- public --------------------------------------------------------------------------------------
local function skipTags(b)
	local len = buffer.len(b)
	local start, stop = 0, len
	-- ID3v2 (possibly several)
	while stop - start >= 10 and buffer.readstring(b, start, 3) == "ID3" do
		local flags = readu8(b, start + 5)
		local size = ((band(readu8(b, start + 6), 0x7F) * 128 + band(readu8(b, start + 7), 0x7F)) * 128
			+ band(readu8(b, start + 8), 0x7F)) * 128 + band(readu8(b, start + 9), 0x7F)
		start += 10 + size + (btest(flags, 0x10) and 10 or 0)
	end
	-- ID3v1 at the end
	if stop - start >= 128 and buffer.readstring(b, stop - 128, 3) == "TAG" then
		stop -= 128
	end
	-- APEv2 footer
	if stop - start >= 32 and buffer.readstring(b, stop - 32, 8) == "APETAGEX" then
		local size = buffer.readu32(b, stop - 32 + 12)
		stop -= size
		if stop - start >= 32 and buffer.readstring(b, stop - 32, 8) == "APETAGEX" then
			stop -= 32
		end
	end
	return math.clamp(start, 0, len), math.clamp(stop, 0, len)
end

function Mp3.probe(b)
	local start, stop = skipTags(b)
	local i, fs = findFrame(b, start, stop - start, 0)
	if fs == 0 then
		return nil
	end
	local h = hdrAt(b, start + i)
	return { sampleRate = sampleRateHz(h), channels = isMono(h) and 1 or 2, bitrate = bitrateKbps(h), layer = 4 - getLayer(h), offset = start + i }
end

function Mp3.decode(b, options)
	options = options or {}
	local yieldFn = options.Yield
	local budget = options.Budget or 0.01
	local start, stop = skipTags(b)
	local d = newDecoder()
	local pcm = table.create(1152 * 2, 0)

	-- first frame: format + optional VBR tag
	local first, fsize = findFrame(b, start, stop - start, 0)
	if fsize == 0 then
		error("MP3: no MPEG audio frames found", 0)
	end
	local fh = hdrAt(b, start + first)
	local channels = isMono(fh) and 1 or 2
	local rate = sampleRateHz(fh)
	local bitrate = bitrateKbps(fh)
	local pos = start + first
	local toSkip, padding, expected = 0, 0, nil
	local vbr, frames, delay, pad = 0, 0, 0, 0
	if 4 - getLayer(fh) == 3 then
		vbr, frames, delay, pad = checkVbrTag(b, pos, fsize)
	end
	if vbr ~= 0 then
		pos += fsize -- the tag frame carries no audio
		if vbr > 0 then
			toSkip = delay
			padding = pad
			expected = frameSamples(fh) * frames - delay - max(pad, 0)
		end
	end
	local maxSamples = options.MaxSeconds and math.floor(options.MaxSeconds * rate) or math.huge
	if expected then
		maxSamples = min(maxSamples, expected)
	end

	-- output buffers grow as needed (f32)
	local cap = math.max(4096, math.floor((stop - pos) / math.max(bitrate, 8) * 8 * rate / 1000) + 4096)
	if expected then
		cap = expected + 4096
	end
	local out = {}
	for c = 1, channels do
		out[c] = buffer.create(cap * 4)
	end
	local count = 0
	local frameCount = 0
	local scale = 1 / 32768
	local t0 = os.clock()
	while pos < stop and count < maxSamples do
		local samples, used, nch = decodeFrame(d, b, pos, stop - pos, pcm)
		if used == 0 then
			break
		end
		pos += used
		if samples > 0 then
			frameCount += 1
			local skipNow = 0
			if toSkip > 0 then
				skipNow = min(toSkip, samples)
				toSkip -= skipNow
			end
			local take = min(samples - skipNow, maxSamples - count)
			if take > 0 then
				if count + take > cap then
					local newCap = math.max(cap * 2, count + take + 4096)
					for c = 1, channels do
						local nb = buffer.create(newCap * 4)
						buffer.copy(nb, 0, out[c], 0, count * 4)
						out[c] = nb
					end
					cap = newCap
				end
				for c = 1, channels do
					local ob = out[c]
					local srcCh = math.min(c, nch) - 1
					local idx = (skipNow * nch + srcCh) + 1
					local w = count * 4
					for _ = 1, take do
						local v = pcm[idx] * scale
						if v > 1 then
							v = 1
						elseif v < -1 then
							v = -1
						end
						buffer.writef32(ob, w, v)
						w += 4
						idx += nch
					end
				end
				count += take
			end
		end
		if yieldFn and os.clock() - t0 > budget then
			yieldFn()
			t0 = os.clock()
		end
	end
	for c = 1, channels do
		if buffer.len(out[c]) ~= count * 4 then
			local nb = buffer.create(count * 4)
			buffer.copy(nb, 0, out[c], 0, count * 4)
			out[c] = nb
		end
	end
	return {
		sampleRate = rate, channels = channels, length = count, data = out,
		bitrate = bitrate, frames = frameCount, delay = delay or 0, padding = padding,
	}
end

return Mp3
