--!native
--!optimize 2
-- VP8 video decoder, for WebM / IVF video: key and inter frames, every intra and inter mode, split motion vectors,
-- golden and alt-ref frames, segmentation, token partitions, the normal and simple loop filters, and the bilinear
-- (versions 1 - 3) motion filters. Decodes exactly as libvpx does.
--   local dec = Vp8.new()
--   local pic = dec:decodeSample(buf, pos, len)   -- one frame (a WebM block / IVF frame); nil when it shows none
--   pic.Y, pic.U, pic.V (buffers), pic.ys, pic.cs (strides), pic.yo, pic.co (0); dec.width, dec.height (the picture's
--   size; the planes are rounded up to whole 16x16 macroblocks)

local band, rshift, lshift = bit32.band, bit32.rshift, bit32.lshift
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local min, max = math.min, math.max

local Vp8 = {}

local function fail(msg)
	error("VP8: " .. msg, 0)
end

local lastYield = os.clock()
local function breathe()
	if task and os.clock() - lastYield > 0.05 then
		task.wait()
		lastYield = os.clock()
	end
end

-- tables from libvpx (flat, 1-based)
local T = {}
T.KF_BMODE = {
	231, 120, 48, 89, 115, 113, 120, 152, 112, 152, 179, 64, 126, 170, 118, 46, 70, 95, 175, 69, 143, 80, 85, 82,
	72, 155, 103, 56, 58, 10, 171, 218, 189, 17, 13, 152, 144, 71, 10, 38, 171, 213, 144, 34, 26, 114, 26, 17,
	163, 44, 195, 21, 10, 173, 121, 24, 80, 195, 26, 62, 44, 64, 85, 170, 46, 55, 19, 136, 160, 33, 206, 71,
	63, 20, 8, 114, 114, 208, 12, 9, 226, 81, 40, 11, 96, 182, 84, 29, 16, 36, 134, 183, 89, 137, 98, 101,
	106, 165, 148, 72, 187, 100, 130, 157, 111, 32, 75, 80, 66, 102, 167, 99, 74, 62, 40, 234, 128, 41, 53, 9,
	178, 241, 141, 26, 8, 107, 104, 79, 12, 27, 217, 255, 87, 17, 7, 74, 43, 26, 146, 73, 166, 49, 23, 157,
	65, 38, 105, 160, 51, 52, 31, 115, 128, 87, 68, 71, 44, 114, 51, 15, 186, 23, 47, 41, 14, 110, 182, 183,
	21, 17, 194, 66, 45, 25, 102, 197, 189, 23, 18, 22, 88, 88, 147, 150, 42, 46, 45, 196, 205, 43, 97, 183,
	117, 85, 38, 35, 179, 61, 39, 53, 200, 87, 26, 21, 43, 232, 171, 56, 34, 51, 104, 114, 102, 29, 93, 77,
	107, 54, 32, 26, 51, 1, 81, 43, 31, 39, 28, 85, 171, 58, 165, 90, 98, 64, 34, 22, 116, 206, 23, 34,
	43, 166, 73, 68, 25, 106, 22, 64, 171, 36, 225, 114, 34, 19, 21, 102, 132, 188, 16, 76, 124, 62, 18, 78,
	95, 85, 57, 50, 48, 51, 193, 101, 35, 159, 215, 111, 89, 46, 111, 60, 148, 31, 172, 219, 228, 21, 18, 111,
	112, 113, 77, 85, 179, 255, 38, 120, 114, 40, 42, 1, 196, 245, 209, 10, 25, 109, 100, 80, 8, 43, 154, 1,
	51, 26, 71, 88, 43, 29, 140, 166, 213, 37, 43, 154, 61, 63, 30, 155, 67, 45, 68, 1, 209, 142, 78, 78,
	16, 255, 128, 34, 197, 171, 41, 40, 5, 102, 211, 183, 4, 1, 221, 51, 50, 17, 168, 209, 192, 23, 25, 82,
	125, 98, 42, 88, 104, 85, 117, 175, 82, 95, 84, 53, 89, 128, 100, 113, 101, 45, 75, 79, 123, 47, 51, 128,
	81, 171, 1, 57, 17, 5, 71, 102, 57, 53, 41, 49, 115, 21, 2, 10, 102, 255, 166, 23, 6, 38, 33, 13,
	121, 57, 73, 26, 1, 85, 41, 10, 67, 138, 77, 110, 90, 47, 114, 101, 29, 16, 10, 85, 128, 101, 196, 26,
	57, 18, 10, 102, 102, 213, 34, 20, 43, 117, 20, 15, 36, 163, 128, 68, 1, 26, 138, 31, 36, 171, 27, 166,
	38, 44, 229, 67, 87, 58, 169, 82, 115, 26, 59, 179, 63, 59, 90, 180, 59, 166, 93, 73, 154, 40, 40, 21,
	116, 143, 209, 34, 39, 175, 57, 46, 22, 24, 128, 1, 54, 17, 37, 47, 15, 16, 183, 34, 223, 49, 45, 183,
	46, 17, 33, 183, 6, 98, 15, 32, 183, 65, 32, 73, 115, 28, 128, 23, 128, 205, 40, 3, 9, 115, 51, 192,
	18, 6, 223, 87, 37, 9, 115, 59, 77, 64, 21, 47, 104, 55, 44, 218, 9, 54, 53, 130, 226, 64, 90, 70,
	205, 40, 41, 23, 26, 57, 54, 57, 112, 184, 5, 41, 38, 166, 213, 30, 34, 26, 133, 152, 116, 10, 32, 134,
	75, 32, 12, 51, 192, 255, 160, 43, 51, 39, 19, 53, 221, 26, 114, 32, 73, 255, 31, 9, 65, 234, 2, 15,
	1, 118, 73, 88, 31, 35, 67, 102, 85, 55, 186, 85, 56, 21, 23, 111, 59, 205, 45, 37, 192, 55, 38, 70,
	124, 73, 102, 1, 34, 98, 102, 61, 71, 37, 34, 53, 31, 243, 192, 69, 60, 71, 38, 73, 119, 28, 222, 37,
	68, 45, 128, 34, 1, 47, 11, 245, 171, 62, 17, 19, 70, 146, 85, 55, 62, 70, 75, 15, 9, 9, 64, 255,
	184, 119, 16, 37, 43, 37, 154, 100, 163, 85, 160, 1, 63, 9, 92, 136, 28, 64, 32, 201, 85, 86, 6, 28,
	5, 64, 255, 25, 248, 1, 56, 8, 17, 132, 137, 255, 55, 116, 128, 58, 15, 20, 82, 135, 57, 26, 121, 40,
	164, 50, 31, 137, 154, 133, 25, 35, 218, 51, 103, 44, 131, 131, 123, 31, 6, 158, 86, 40, 64, 135, 148, 224,
	45, 183, 128, 22, 26, 17, 131, 240, 154, 14, 1, 209, 83, 12, 13, 54, 192, 255, 68, 47, 28, 45, 16, 21,
	91, 64, 222, 7, 1, 197, 56, 21, 39, 155, 60, 138, 23, 102, 213, 85, 26, 85, 85, 128, 128, 32, 146, 171,
	18, 11, 7, 63, 144, 171, 4, 4, 246, 35, 27, 10, 146, 174, 171, 12, 26, 128, 190, 80, 35, 99, 180, 80,
	126, 54, 45, 85, 126, 47, 87, 176, 51, 41, 20, 32, 101, 75, 128, 139, 118, 146, 116, 128, 85, 56, 41, 15,
	176, 236, 85, 37, 9, 62, 146, 36, 19, 30, 171, 255, 97, 27, 20, 71, 30, 17, 119, 118, 255, 17, 18, 138,
	101, 38, 60, 138, 55, 70, 43, 26, 142, 138, 45, 61, 62, 219, 1, 81, 188, 64, 32, 41, 20, 117, 151, 142,
	20, 21, 163, 112, 19, 12, 61, 195, 128, 48, 4, 24,
}
T.COEF_DEFAULT = {
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128, 189, 129, 242, 255,
	227, 213, 255, 219, 128, 128, 128, 106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128, 1, 98, 248, 255, 236, 226,
	255, 255, 128, 128, 128, 181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128, 78, 134, 202, 247, 198, 180, 255, 219,
	128, 128, 128, 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128, 184, 150, 247, 255, 236, 224, 128, 128, 128, 128,
	128, 77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128, 1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128, 170,
	139, 241, 252, 236, 209, 255, 255, 128, 128, 128, 37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128, 1, 204, 254,
	255, 245, 255, 128, 128, 128, 128, 128, 207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128, 102, 103, 231, 255, 211,
	171, 128, 128, 128, 128, 128, 1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128, 177, 135, 243, 255, 234, 225, 128,
	128, 128, 128, 128, 80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128,
	128, 128, 246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62, 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1, 68, 47,
	146, 208, 149, 167, 221, 162, 255, 223, 128, 1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128, 184, 141, 234, 253,
	222, 220, 255, 199, 128, 128, 128, 81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128, 1, 129, 232, 253, 214, 197,
	242, 196, 255, 255, 128, 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128, 23, 91, 163, 242, 170, 187, 247, 210,
	255, 255, 128, 1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128, 109, 178, 241, 255, 231, 245, 255, 255, 128, 128,
	128, 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128, 1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128, 94,
	136, 225, 251, 218, 190, 255, 255, 128, 128, 128, 22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128, 1, 182, 249,
	255, 232, 235, 128, 128, 128, 128, 128, 124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128, 35, 77, 181, 251, 193,
	211, 255, 205, 128, 128, 128, 1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128, 121, 141, 235, 255, 225, 227, 255,
	255, 128, 128, 128, 45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128, 1, 1, 251, 255, 213, 255, 128, 128, 128,
	128, 128, 203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128, 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
	253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128, 175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128, 73, 17,
	171, 221, 161, 179, 236, 167, 255, 234, 128, 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128, 239, 90, 244, 250,
	211, 209, 255, 255, 128, 128, 128, 155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128, 1, 24, 239, 251, 218, 219,
	255, 205, 128, 128, 128, 201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128, 69, 46, 190, 239, 201, 218, 255, 228,
	128, 128, 128, 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128, 223, 165, 249, 255, 213, 255, 128, 128, 128, 128,
	128, 141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128, 1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128, 190,
	36, 230, 255, 236, 255, 128, 128, 128, 128, 128, 149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 1, 226, 255,
	128, 128, 128, 128, 128, 128, 128, 128, 247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128, 240, 128, 255, 128, 128,
	128, 128, 128, 128, 128, 128, 1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128, 213, 62, 250, 255, 255, 128, 128,
	128, 128, 128, 128, 55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
	202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255, 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128, 61, 46,
	138, 219, 151, 178, 240, 170, 255, 216, 128, 1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128, 166, 109, 228, 252,
	211, 215, 255, 174, 128, 128, 128, 39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128, 1, 52, 220, 246, 198, 199,
	249, 220, 255, 255, 128, 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128, 24, 71, 130, 219, 154, 170, 243, 182,
	255, 255, 128, 1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128, 149, 150, 226, 252, 216, 205, 255, 171, 128, 128,
	128, 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128, 1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128, 123,
	102, 209, 247, 188, 196, 255, 233, 128, 128, 128, 20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128, 1, 222, 248,
	255, 216, 213, 128, 128, 128, 128, 128, 168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128, 47, 116, 215, 255, 211,
	212, 255, 255, 128, 128, 128, 1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128, 141, 84, 213, 252, 201, 202, 255,
	219, 128, 128, 128, 42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128, 1, 1, 255, 128, 128, 128, 128, 128, 128,
	128, 128, 244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128, 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
}
T.COEF_UPDATE = {
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255, 223, 241, 252, 255,
	255, 255, 255, 255, 255, 255, 255, 249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 244, 252, 255, 255, 255,
	255, 255, 255, 255, 255, 234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255, 239, 253, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255, 251,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 254, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255, 250, 255, 254, 255, 254, 255, 255,
	255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255, 234, 250,
	241, 250, 253, 255, 253, 254, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 223, 254, 254, 255,
	255, 255, 255, 255, 255, 255, 255, 238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 248, 254, 255, 255, 255,
	255, 255, 255, 255, 255, 249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 247, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 252,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255, 234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255, 251, 251,
	243, 253, 254, 255, 254, 255, 255, 255, 255, 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 236, 253, 254, 255,
	255, 255, 255, 255, 255, 255, 255, 251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255, 254, 254, 255, 255, 255,
	255, 255, 255, 255, 255, 254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255, 248, 254,
	249, 253, 255, 255, 255, 255, 255, 255, 255, 255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255, 246, 253, 253, 255,
	255, 255, 255, 255, 255, 255, 255, 252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 254, 252, 255, 255, 255,
	255, 255, 255, 255, 255, 248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 254, 254, 255, 255, 255, 255,
	255, 255, 255, 255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255, 245, 251, 254, 255, 255, 255, 255, 255, 255, 255,
	255, 253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255, 252,
	253, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 252, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 250, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
}
T.DC_Q = {
	4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 20, 21, 21, 22, 22,
	23, 23, 24, 25, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
	44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66,
	67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
	91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118, 122, 124, 126, 128, 130, 132, 134, 136,
	138, 140, 143, 145, 148, 151, 154, 157,
}
T.AC_Q = {
	4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
	52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92,
	94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
	155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229, 234, 239, 245,
	249, 254, 259, 264, 269, 274, 279, 284,
}
T.MV_DEFAULT = {
	162, 128, 225, 146, 172, 147, 214, 39, 156, 128, 129, 132, 75, 145, 178, 206, 239, 254, 254, 164, 128, 204, 170, 119,
	235, 140, 230, 228, 128, 130, 130, 74, 148, 180, 203, 236, 254, 254,
}
T.MV_UPDATE = {
	237, 246, 253, 253, 254, 254, 254, 254, 254, 254, 254, 254, 254, 254, 250, 250, 252, 254, 254, 231, 243, 245, 253, 254,
	254, 254, 254, 254, 254, 254, 254, 254, 254, 251, 251, 254, 254, 254,
}


local POW2 = table.create(64, 1)
for i = 2, 64 do
	POW2[i] = POW2[i - 1] * 2
end
local NORM = table.create(257, 0) -- [range + 1] -> shift that brings range to 128..255
for r = 1, 255 do
	local s = 0
	while lshift(r, s) < 128 do
		s += 1
	end
	NORM[r + 1] = s
end

-- trees (vpx_tree_index arrays, 1-based copies)
local BMODE_TREE = { 0, 2, -1, 4, -2, 6, 8, 12, -3, 10, -5, -6, -4, 14, -7, 16, -8, -9 }
local YMODE_TREE = { 0, 2, 4, 6, -1, -2, -3, -4 }
local KF_YMODE_TREE = { -4, 2, 4, 6, 0, -1, -2, -3 }
local UV_MODE_TREE = { 0, 2, -1, 4, -2, -3 }
local SMALL_MV_TREE = { 2, 8, 4, 6, 0, -1, -2, -3, 10, 12, -4, -5, -6, -7 }

local YMODE_PROB = { 112, 86, 140, 37 }
local KF_YMODE_PROB = { 145, 156, 163, 128 }
local UV_MODE_PROB = { 162, 101, 204 }
local KF_UV_MODE_PROB = { 142, 114, 183 }
local BMODE_PROB = { 120, 90, 79, 133, 87, 85, 80, 111, 151 }
local MODE_CONTEXTS = { 7, 1, 1, 143, 14, 18, 14, 107, 135, 64, 57, 68, 60, 56, 128, 65, 159, 134, 128, 34, 234, 188, 128, 28 }
local SUB_MV_REF_PROB = { 147, 136, 18, 223, 1, 34, 106, 145, 1, 208, 1, 1, 179, 121, 1, 223, 1, 34, 179, 121, 1, 208, 1, 1 }
local MBSPLIT_OFFSET = { [0] = { 0, 8 }, { 0, 2 }, { 0, 2, 8, 10 }, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } }
local MBSPLIT_FILL_COUNT = { [0] = 8, 8, 4, 1 }
local MBSPLIT_FILL = {
	[0] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
	{ 0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15 },
	{ 0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15 },
	{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
}
local BANDS = { 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 }
local ZIGZAG = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 }
local CAT = { [0] = { 173, 148, 140 }, { 176, 155, 140, 135 }, { 180, 157, 141, 134, 130 },
	{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 } }
local SIXTAP = {
	[0] = { 0, 0, 128, 0, 0, 0 }, { 0, -6, 123, 12, -1, 0 }, { 2, -11, 108, 36, -8, 1 }, { 0, -9, 93, 50, -6, 0 },
	{ 3, -16, 77, 77, -16, 3 }, { 0, -6, 50, 93, -9, 0 }, { 1, -8, 36, 108, -11, 2 }, { 0, -1, 12, 123, -6, 0 },
}
local MODE_LF = { [0] = 1, 1, 1, 1, 0, 2, 2, 1, 2, 3 } -- mode -> loop filter mode delta index

-- modes
local DC_PRED, V_PRED, H_PRED, TM_PRED, B_PRED = 0, 1, 2, 3, 4
local NEARESTMV, NEARMV, ZEROMV, NEWMV, SPLITMV = 5, 6, 7, 8, 9

------------------------------------------------------------------------------------------------------------------------
-- the boolean decoder (one at a time: its state in these locals)

local bBuf, bPos, bStop, bValue, bCnt, bRange = buffer.create(1), 0, 0, 0, 0, 255

local function bStart(buf, pos, size)
	bBuf, bStop = buf, pos + max(size, 0)
	bValue = size > 0 and readu8(buf, pos) or 0
	bPos = pos + 1
	bCnt, bRange = 0, 255
end

local function bSave()
	return { bBuf, bPos, bStop, bValue, bCnt, bRange }
end

local function bLoad(s)
	bBuf, bPos, bStop, bValue, bCnt, bRange = s[1], s[2], s[3], s[4], s[5], s[6]
end

local function bRead(p)
	local cnt, value = bCnt, bValue
	if cnt < 8 then
		local pos, stop, buf = bPos, bStop, bBuf
		repeat
			value = value * 256 + (pos < stop and readu8(buf, pos) or 0)
			pos += 1
			cnt += 8
		until cnt >= 16
		bPos = pos
	end
	local range = bRange
	local split = 1 + rshift((range - 1) * p, 8)
	local big = split * POW2[cnt + 1]
	local bit
	if value >= big then
		range -= split
		value -= big
		bit = 1
	else
		range = split
		bit = 0
	end
	local shift = NORM[range + 1]
	bRange = lshift(range, shift)
	bCnt = cnt - shift
	bValue = value
	return bit
end

local function bLiteral(n)
	local v = 0
	for _ = 1, n do
		v = v * 2 + bRead(128)
	end
	return v
end

local function bTree(tree, probs, base)
	local i = 0
	repeat
		i = tree[i + bRead(probs[base + i // 2 + 1]) + 1]
	until i <= 0
	return -i
end

-- a signed value: magnitude of n bits, then its sign
local function bSigned(n)
	local v = bLiteral(n)
	if bRead(128) == 1 then
		v = -v
	end
	return v
end

------------------------------------------------------------------------------------------------------------------------
-- frames: Y, U and V planes the size of the whole macroblocks

local function newFrame(w, h)
	local mbCols, mbRows = (w + 15) // 16, (h + 15) // 16
	local aw, ah = mbCols * 16, mbRows * 16
	return {
		w = w, h = h, aw = aw, ah = ah, cw = aw // 2, ch = ah // 2,
		ys = aw, cs = aw // 2, yo = 0, co = 0,
		Y = buffer.create(aw * ah), U = buffer.create(aw * ah // 4), V = buffer.create(aw * ah // 4),
	}
end

local Decoder = {}
Decoder.__index = Decoder

local function defaultCoefProbs()
	return table.clone(T.COEF_DEFAULT)
end

function Vp8.new()
	local self = setmetatable({}, Decoder)
	self.width, self.height = 0, 0
	self.cropX, self.cropY = 0, 0
	self.fullRange, self.bt709 = false, false
	self.haveKey = false
	self.coef = defaultCoefProbs()
	self.ymodeProb = table.clone(YMODE_PROB)
	self.uvModeProb = table.clone(UV_MODE_PROB)
	self.mvProb = table.clone(T.MV_DEFAULT)
	self.segEnabled = false
	self.segAbs = false
	self.segQ = { [0] = 0, 0, 0, 0 }
	self.segLf = { [0] = 0, 0, 0, 0 }
	self.segTree = { 255, 255, 255 }
	self.lfDeltaEnabled = false
	self.refDeltas = { [0] = 0, 0, 0, 0 }
	self.modeDeltas = { [0] = 0, 0, 0, 0 }
	self.signBias = { [0] = 0, 0, 0, 0 }
	self.pool = {}
	return self
end

-- the frame buffer to decode into: one no reference frame holds
function Decoder:takeFrame()
	local used = {}
	if self.last then
		used[self.last] = true
	end
	if self.golden then
		used[self.golden] = true
	end
	if self.altref then
		used[self.altref] = true
	end
	for _, f in ipairs(self.pool) do
		if not used[f] and f.w == self.width and f.h == self.height then
			return f
		end
	end
	local f = newFrame(self.width, self.height)
	table.insert(self.pool, f)
	return f
end

function Decoder:setSize(w, h)
	if w == self.width and h == self.height and self.mbCols then
		return
	end
	if w < 1 or h < 1 then
		fail("broken data (picture size 0)")
	end
	self.width, self.height = w, h
	local mbCols, mbRows = (w + 15) // 16, (h + 15) // 16
	self.mbCols, self.mbRows = mbCols, mbRows
	local stride = mbCols + 1
	self.miStride = stride
	local n = (mbRows + 1) * stride + 1
	-- per macroblock (with a border row above and column left, all zero: intra, DC_PRED, no motion)
	self.miMode = table.create(n, 0)
	self.miUv = table.create(n, 0)
	self.miRef = table.create(n, 0)
	self.miMvR = table.create(n, 0)
	self.miMvC = table.create(n, 0)
	self.miSeg = table.create(n, 0)
	self.miSkip = table.create(n, 0)
	self.miPart = table.create(n, 0)
	self.bMode = table.create(n * 16, 0)
	self.bMvR = table.create(n * 16, 0)
	self.bMvC = table.create(n * 16, 0)
	self.aboveCtx = table.create(mbCols * 9, 0)
	self.pool = {}
	self.last, self.golden, self.altref = nil, nil, nil
end

------------------------------------------------------------------------------------------------------------------------
-- macroblock modes and motion vectors (the first partition)

-- module state for the frame being decoded
local D -- the decoder
local miMode, miUv, miRef, miMvR, miMvC, miSeg, miSkip, miPart, bMode, bMvR, bMvC
local miStride, mbCols, mbRows
local mvProb
local nmR, nmC, cnt = table.create(4, 0), table.create(4, 0), table.create(4, 0)

local function readMvComponent(base)
	local p = mvProb
	local x
	if bRead(p[base + 1]) == 1 then
		x = 0
		for i = 0, 2 do
			x += bRead(p[base + 10 + i]) * POW2[i + 1]
		end
		for i = 9, 4, -1 do
			x += bRead(p[base + 10 + i]) * POW2[i + 1]
		end
		if band(x, 0xFFF0) == 0 or bRead(p[base + 13]) == 1 then
			x += 8
		end
	else
		x = bTree(SMALL_MV_TREE, p, base + 2)
	end
	if x ~= 0 and bRead(p[base + 2]) == 1 then
		x = -x
	end
	return x
end

local function clampMv(r, c, mbRow, mbCol)
	local toLeft, toRight = -mbCol * 128 - 128, (mbCols - 1 - mbCol) * 128 + 128
	local toTop, toBottom = -mbRow * 128 - 128, (mbRows - 1 - mbRow) * 128 + 128
	if c < toLeft then
		c = toLeft
	elseif c > toRight then
		c = toRight
	end
	if r < toTop then
		r = toTop
	elseif r > toBottom then
		r = toBottom
	end
	return r, c
end

local function decodeSplit(mi, bestR, bestC)
	local s, numP = 3, 16
	if bRead(110) == 1 then
		s, numP = 2, 4
		if bRead(111) == 1 then
			s = bRead(150)
			numP = 2
		end
	end
	local left, above = mi - 1, mi - miStride
	local bb = (mi - 1) * 16
	local offsets = MBSPLIT_OFFSET[s]
	local fillCount = MBSPLIT_FILL_COUNT[s]
	local fill = MBSPLIT_FILL[s]
	for j = 0, numP - 1 do
		local k = offsets[j + 1]
		local lr, lc, ar, ac
		if band(k, 3) == 0 then
			if miMode[left] ~= SPLITMV then
				lr, lc = miMvR[left], miMvC[left]
			else
				local q = (left - 1) * 16 + k + 3 + 1
				lr, lc = bMvR[q], bMvC[q]
			end
		else
			lr, lc = bMvR[bb + k], bMvC[bb + k]
		end
		if k < 4 then
			if miMode[above] ~= SPLITMV then
				ar, ac = miMvR[above], miMvC[above]
			else
				local q = (above - 1) * 16 + k + 12 + 1
				ar, ac = bMvR[q], bMvC[q]
			end
		else
			ar, ac = bMvR[bb + k - 3], bMvC[bb + k - 3]
		end
		local lez = (lr == 0 and lc == 0) and 1 or 0
		local aez = (ar == 0 and ac == 0) and 1 or 0
		local lea = (lr == ar and lc == ac) and 1 or 0
		local pb = (aez * 4 + lez * 2 + lea) * 3
		local r, c
		if bRead(SUB_MV_REF_PROB[pb + 1]) == 1 then
			if bRead(SUB_MV_REF_PROB[pb + 2]) == 1 then
				r, c = 0, 0
				if bRead(SUB_MV_REF_PROB[pb + 3]) == 1 then
					r = readMvComponent(0) * 2 + bestR
					c = readMvComponent(19) * 2 + bestC
				end
			else
				r, c = ar, ac
			end
		else
			r, c = lr, lc
		end
		local f0 = j * fillCount
		for f = 1, fillCount do
			local q = bb + fill[f0 + f] + 1
			bMvR[q], bMvC[q] = r, c
		end
	end
	miPart[mi] = s
end

local function readInterModes(mi, mbRow, mbCol, probLast, probGf)
	local ref = 1
	if bRead(probLast) == 1 then
		ref = 2 + bRead(probGf)
	end
	miRef[mi] = ref
	local signBias = D.signBias
	local myBias = signBias[ref]
	for i = 1, 4 do
		nmR[i], nmC[i], cnt[i] = 0, 0, 0
	end
	local idx = 1
	local above, left = mi - miStride, mi - 1
	local aboveLeft = above - 1
	local rf = miRef[above]
	if rf ~= 0 then
		local r, c = miMvR[above], miMvC[above]
		if r ~= 0 or c ~= 0 then
			if signBias[rf] ~= myBias then
				r, c = -r, -c
			end
			idx += 1
			nmR[idx], nmC[idx] = r, c
		end
		cnt[idx] += 2
	end
	rf = miRef[left]
	if rf ~= 0 then
		local r, c = miMvR[left], miMvC[left]
		if r ~= 0 or c ~= 0 then
			if signBias[rf] ~= myBias then
				r, c = -r, -c
			end
			if r ~= nmR[idx] or c ~= nmC[idx] then
				idx += 1
				nmR[idx], nmC[idx] = r, c
			end
			cnt[idx] += 2
		else
			cnt[1] += 2
		end
	end
	rf = miRef[aboveLeft]
	if rf ~= 0 then
		local r, c = miMvR[aboveLeft], miMvC[aboveLeft]
		if r ~= 0 or c ~= 0 then
			if signBias[rf] ~= myBias then
				r, c = -r, -c
			end
			if r ~= nmR[idx] or c ~= nmC[idx] then
				idx += 1
				nmR[idx], nmC[idx] = r, c
			end
			cnt[idx] += 1
		else
			cnt[1] += 1
		end
	end
	local mode, mr, mc = ZEROMV, 0, 0
	if bRead(MODE_CONTEXTS[cnt[1] * 4 + 1]) == 1 then
		-- (the above-left vector merges with the nearest when they are the same)
		if cnt[4] > 0 and nmR[idx] == nmR[2] and nmC[idx] == nmC[2] then
			cnt[2] += 1
		end
		if cnt[3] > cnt[2] then
			cnt[2], cnt[3] = cnt[3], cnt[2]
			nmR[2], nmR[3] = nmR[3], nmR[2]
			nmC[2], nmC[3] = nmC[3], nmC[2]
		end
		if bRead(MODE_CONTEXTS[cnt[2] * 4 + 2]) == 1 then
			if bRead(MODE_CONTEXTS[cnt[3] * 4 + 3]) == 1 then
				local ni = cnt[2] >= cnt[1] and 2 or 1
				local bestR, bestC = clampMv(nmR[ni], nmC[ni], mbRow, mbCol)
				local splitCnt = (miMode[above] == SPLITMV and 2 or 0) + (miMode[left] == SPLITMV and 2 or 0)
					+ (miMode[aboveLeft] == SPLITMV and 1 or 0)
				if bRead(MODE_CONTEXTS[splitCnt * 4 + 4]) == 1 then
					decodeSplit(mi, bestR, bestC)
					local q = (mi - 1) * 16 + 16
					mode, mr, mc = SPLITMV, bMvR[q], bMvC[q]
				else
					mr = readMvComponent(0) * 2 + bestR
					mc = readMvComponent(19) * 2 + bestC
					mode = NEWMV
				end
			else
				mode = NEARMV
				mr, mc = clampMv(nmR[3], nmC[3], mbRow, mbCol)
			end
		else
			mode = NEARESTMV
			mr, mc = clampMv(nmR[2], nmC[2], mbRow, mbCol)
		end
	end
	miMode[mi], miMvR[mi], miMvC[mi] = mode, mr, mc
end

-- the mode of block b's neighbour above / left in a key frame (a 16x16 mode stands for its matching 4x4 one)
local MB_TO_B = { [0] = 0, 2, 3, 1 }
local function aboveBlockMode(mi, b)
	if b < 4 then
		local a = mi - miStride
		local m = miMode[a]
		if m == B_PRED then
			return bMode[(a - 1) * 16 + b + 12 + 1]
		end
		return MB_TO_B[m] or 0
	end
	return bMode[(mi - 1) * 16 + b - 4 + 1]
end
local function leftBlockMode(mi, b)
	if band(b, 3) == 0 then
		local l = mi - 1
		local m = miMode[l]
		if m == B_PRED then
			return bMode[(l - 1) * 16 + b + 3 + 1]
		end
		return MB_TO_B[m] or 0
	end
	return bMode[(mi - 1) * 16 + b - 1 + 1]
end

local function decodeModes(keyFrame, updateMap, skipProb, probIntra, probLast, probGf)
	local segTree = D.segTree
	local ymodeProb, uvModeProb = D.ymodeProb, D.uvModeProb
	for mbRow = 0, mbRows - 1 do
		for mbCol = 0, mbCols - 1 do
			local mi = (mbRow + 1) * miStride + mbCol + 2
			if updateMap then
				if bRead(segTree[1]) == 1 then
					miSeg[mi] = 2 + bRead(segTree[3])
				else
					miSeg[mi] = bRead(segTree[2])
				end
			elseif keyFrame then
				miSeg[mi] = 0
			end
			miSkip[mi] = skipProb and bRead(skipProb) or 0
			if keyFrame then
				miRef[mi], miMvR[mi], miMvC[mi] = 0, 0, 0
				local m = bTree(KF_YMODE_TREE, KF_YMODE_PROB, 0)
				miMode[mi] = m
				if m == B_PRED then
					local bb = (mi - 1) * 16
					for b = 0, 15 do
						local A, L = aboveBlockMode(mi, b), leftBlockMode(mi, b)
						bMode[bb + b + 1] = bTree(BMODE_TREE, T.KF_BMODE, (A * 10 + L) * 9)
					end
				end
				miUv[mi] = bTree(UV_MODE_TREE, KF_UV_MODE_PROB, 0)
			elseif bRead(probIntra) == 1 then
				readInterModes(mi, mbRow, mbCol, probLast, probGf)
			else
				miRef[mi], miMvR[mi], miMvC[mi] = 0, 0, 0
				local m = bTree(YMODE_TREE, ymodeProb, 0)
				miMode[mi] = m
				if m == B_PRED then
					local bb = (mi - 1) * 16
					for b = 1, 16 do
						bMode[bb + b] = bTree(BMODE_TREE, BMODE_PROB, 0)
					end
				end
				miUv[mi] = bTree(UV_MODE_TREE, uvModeProb, 0)
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- coefficients

local COEF -- the frame's coefficient probabilities (flat: ((type * 8 + band) * 3 + ctx) * 11 + node + 1)
local coef = table.create(400, 0) -- the macroblock's 25 blocks of 16 (quantized)
local eobs = table.create(25, 0)
local aboveCtx -- 9 a column: Y 4, U 2, V 2, Y2
local leftCtx = table.create(9, 0)

-- one block's tokens; returns the position after its last coefficient (0 when it has none)
local function getCoeffs(tb, ctx, n, ob)
	local P = COEF
	local p = tb + n * 33 + ctx * 11
	if bRead(P[p + 1]) == 0 then
		return 0
	end
	while true do
		n += 1
		if bRead(P[p + 2]) == 0 then
			p = tb + BANDS[n + 1] * 33
		else
			local v
			if bRead(P[p + 3]) == 0 then
				v = 1
				p = tb + BANDS[n + 1] * 33 + 11
			else
				if bRead(P[p + 4]) == 0 then
					if bRead(P[p + 5]) == 0 then
						v = 2
					else
						v = 3 + bRead(P[p + 6])
					end
				elseif bRead(P[p + 7]) == 0 then
					if bRead(P[p + 8]) == 0 then
						v = 5 + bRead(159)
					else
						v = 7 + 2 * bRead(165)
						v += bRead(145)
					end
				else
					local b1 = bRead(P[p + 9])
					local b0 = bRead(P[p + 10 + b1])
					local cat = 2 * b1 + b0
					v = 0
					for _, pr in ipairs(CAT[cat]) do
						v = v + v + bRead(pr)
					end
					v += 3 + 8 * POW2[cat + 1]
				end
				p = tb + BANDS[n + 1] * 33 + 22
			end
			if bRead(128) == 1 then
				v = -v
			end
			coef[ob + ZIGZAG[n] + 1] = v
			if n == 16 or bRead(P[p + 1]) == 0 then
				return n
			end
		end
		if n == 16 then
			return 16
		end
	end
end

-- the macroblock's tokens; returns how many there were (0: none)
local function decodeTokens(mbCol, is4x4)
	local a = mbCol * 9
	local total = 0
	local tb, skipDc
	if not is4x4 then
		local nz = getCoeffs(264, aboveCtx[a + 9] + leftCtx[9], 0, 384)
		local f = nz > 0 and 1 or 0
		aboveCtx[a + 9], leftCtx[9] = f, f
		eobs[25] = nz
		total += nz - 16
		tb, skipDc = 0, 1
	else
		tb, skipDc = 792, 0
	end
	for i = 0, 15 do
		local ai, li = a + band(i, 3) + 1, rshift(i, 2) + 1
		local nz = getCoeffs(tb, aboveCtx[ai] + leftCtx[li], skipDc, i * 16)
		local f = nz > 0 and 1 or 0
		aboveCtx[ai], leftCtx[li] = f, f
		nz += skipDc
		eobs[i + 1] = nz
		total += nz
	end
	for i = 16, 23 do
		local plane = i > 19 and 2 or 0
		local ai = a + 4 + plane + band(i, 1) + 1
		local li = 4 + plane + (band(i, 3) > 1 and 1 or 0) + 1
		local nz = getCoeffs(528, aboveCtx[ai] + leftCtx[li], 0, i * 16)
		local f = nz > 0 and 1 or 0
		aboveCtx[ai], leftCtx[li] = f, f
		eobs[i + 1] = nz
		total += nz
	end
	return total
end

------------------------------------------------------------------------------------------------------------------------
-- inverse transforms

local X = table.create(16, 0)
local Tmp = table.create(16, 0)

-- X (dequantized, 16) -> added to the 4x4 block at off
local function idctAdd(buf, off, stride)
	for i = 1, 4 do
		local i0, i1, i2, i3 = X[i], X[i + 4], X[i + 8], X[i + 12]
		local a1, b1 = i0 + i2, i0 - i2
		local c1 = (i1 * 35468) // 65536 - (i3 + (i3 * 20091) // 65536)
		local d1 = (i1 + (i1 * 20091) // 65536) + (i3 * 35468) // 65536
		Tmp[i], Tmp[i + 12] = a1 + d1, a1 - d1
		Tmp[i + 4], Tmp[i + 8] = b1 + c1, b1 - c1
	end
	for r = 0, 3 do
		local k = r * 4
		local i0, i1, i2, i3 = Tmp[k + 1], Tmp[k + 2], Tmp[k + 3], Tmp[k + 4]
		local a1, b1 = i0 + i2, i0 - i2
		local c1 = (i1 * 35468) // 65536 - (i3 + (i3 * 20091) // 65536)
		local d1 = (i1 + (i1 * 20091) // 65536) + (i3 * 35468) // 65536
		local o = off + r * stride
		local v = readu8(buf, o) + (a1 + d1 + 4) // 8
		writeu8(buf, o, math.clamp(v, 0, 255))
		v = readu8(buf, o + 1) + (b1 + c1 + 4) // 8
		writeu8(buf, o + 1, math.clamp(v, 0, 255))
		v = readu8(buf, o + 2) + (b1 - c1 + 4) // 8
		writeu8(buf, o + 2, math.clamp(v, 0, 255))
		v = readu8(buf, o + 3) + (a1 - d1 + 4) // 8
		writeu8(buf, o + 3, math.clamp(v, 0, 255))
	end
end

local function dcAdd(buf, off, stride, dc)
	local a = (dc + 4) // 8
	if a == 0 then
		return
	end
	for r = 0, 3 do
		local o = off + r * stride
		for c = 0, 3 do
			local v = readu8(buf, o + c) + a
			writeu8(buf, o + c, math.clamp(v, 0, 255))
		end
	end
end

-- block b's residual (coef at ob, eob) with dequant factors (dcq for coefficient 0) added at off
local function residual(buf, off, stride, ob, eob, dcq, acq)
	if eob > 1 then
		X[1] = coef[ob + 1] * dcq
		coef[ob + 1] = 0
		for i = 2, 16 do
			X[i] = coef[ob + i] * acq
			coef[ob + i] = 0
		end
		idctAdd(buf, off, stride)
	else
		local dc = coef[ob + 1] * dcq
		coef[ob + 1] = 0
		coef[ob + 2] = 0
		dcAdd(buf, off, stride, dc)
	end
end

-- the second order (Y2) block -> each Y block's DC (coef[b * 16 + 1])
local function inverseWalsh(eob, dcq, acq)
	if eob > 1 then
		for i = 1, 16 do
			X[i] = coef[384 + i] * (i == 1 and dcq or acq)
			coef[384 + i] = 0
		end
		for i = 1, 4 do
			local a1 = X[i] + X[i + 12]
			local b1 = X[i + 4] + X[i + 8]
			local c1 = X[i + 4] - X[i + 8]
			local d1 = X[i] - X[i + 12]
			Tmp[i] = a1 + b1
			Tmp[i + 4] = c1 + d1
			Tmp[i + 8] = a1 - b1
			Tmp[i + 12] = d1 - c1
		end
		for r = 0, 3 do
			local k = r * 4
			local a1 = Tmp[k + 1] + Tmp[k + 4]
			local b1 = Tmp[k + 2] + Tmp[k + 3]
			local c1 = Tmp[k + 2] - Tmp[k + 3]
			local d1 = Tmp[k + 1] - Tmp[k + 4]
			coef[(k + 0) * 16 + 1] = (a1 + b1 + 3) // 8
			coef[(k + 1) * 16 + 1] = (c1 + d1 + 3) // 8
			coef[(k + 2) * 16 + 1] = (a1 - b1 + 3) // 8
			coef[(k + 3) * 16 + 1] = (d1 - c1 + 3) // 8
		end
	else
		local dc = (coef[385] * dcq + 3) // 8
		coef[385], coef[386] = 0, 0
		for b = 0, 15 do
			coef[b * 16 + 1] = dc
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- intra prediction

local A = table.create(21, 0) -- above: [1] above-left, [2..17] above, [18..21] above-right
local Lf = table.create(16, 0) -- left

-- the edge around the block at (x, y), n wide, in a plane w wide (unfiltered neighbours; 127 above the picture, 129 left of it)
local function edges(buf, stride, x, y, n, rightN, planeW)
	if y == 0 then
		for i = 1, n + 1 + rightN do
			A[i] = 127
		end
	else
		local o = (y - 1) * stride
		A[1] = x == 0 and 129 or readu8(buf, o + x - 1)
		for i = 0, n - 1 do
			A[i + 2] = readu8(buf, o + x + i)
		end
		if rightN > 0 then
			if x + n < planeW then
				for i = 0, rightN - 1 do
					A[n + 2 + i] = readu8(buf, o + x + n + i)
				end
			else
				local v = readu8(buf, o + planeW - 1)
				for i = 0, rightN - 1 do
					A[n + 2 + i] = v
				end
			end
		end
	end
	if x == 0 then
		for i = 1, n do
			Lf[i] = 129
		end
	else
		for i = 0, n - 1 do
			Lf[i + 1] = readu8(buf, (y + i) * stride + x - 1)
		end
	end
end

local function predictMb(buf, stride, x, y, n, mode, haveUp, haveLeft)
	local o = y * stride + x
	if mode == DC_PRED then
		local v
		if haveUp and haveLeft then
			local s = 0
			for i = 1, n do
				s += A[i + 1] + Lf[i]
			end
			v = (s + n) // (2 * n)
		elseif haveUp then
			local s = 0
			for i = 1, n do
				s += A[i + 1]
			end
			v = (s + n // 2) // n
		elseif haveLeft then
			local s = 0
			for i = 1, n do
				s += Lf[i]
			end
			v = (s + n // 2) // n
		else
			v = 128
		end
		for r = 0, n - 1 do
			buffer.fill(buf, o + r * stride, v, n)
		end
	elseif mode == V_PRED then
		for r = 0, n - 1 do
			local q = o + r * stride
			for c = 0, n - 1 do
				writeu8(buf, q + c, A[c + 2])
			end
		end
	elseif mode == H_PRED then
		for r = 0, n - 1 do
			buffer.fill(buf, o + r * stride, Lf[r + 1], n)
		end
	else -- TM_PRED
		local tl = A[1]
		for r = 0, n - 1 do
			local q = o + r * stride
			local l = Lf[r + 1] - tl
			for c = 0, n - 1 do
				local v = l + A[c + 2]
				writeu8(buf, q + c, math.clamp(v, 0, 255))
			end
		end
	end
end

-- 4x4 prediction into S (stride 24: [-1..19] x [-1..15] around the macroblock)
local S = buffer.create(24 * 17)
local function avg3(a, b, c)
	return (a + 2 * b + c + 2) // 4
end
local function avg2(a, b)
	return (a + b + 1) // 2
end

local function predict4(bx, by, mode)
	local o = (by + 1) * 24 + bx + 1 -- the block's top-left
	local up = o - 24
	local tl = readu8(S, up - 1)
	local a0, a1, a2, a3 = readu8(S, up), readu8(S, up + 1), readu8(S, up + 2), readu8(S, up + 3)
	local a4, a5, a6, a7 = readu8(S, up + 4), readu8(S, up + 5), readu8(S, up + 6), readu8(S, up + 7)
	local l0, l1, l2, l3 = readu8(S, o - 1), readu8(S, o + 23), readu8(S, o + 47), readu8(S, o + 71)
	if mode == 0 then -- DC
		local v = (a0 + a1 + a2 + a3 + l0 + l1 + l2 + l3 + 4) // 8
		for y = 0, 3 do
			buffer.fill(S, o + y * 24, v, 4)
		end
	elseif mode == 1 then -- TM
		for y = 0, 3 do
			local l = (y == 0 and l0 or y == 1 and l1 or y == 2 and l2 or l3) - tl
			local q = o + y * 24
			local v = l + a0
			writeu8(S, q, math.clamp(v, 0, 255))
			v = l + a1
			writeu8(S, q + 1, math.clamp(v, 0, 255))
			v = l + a2
			writeu8(S, q + 2, math.clamp(v, 0, 255))
			v = l + a3
			writeu8(S, q + 3, math.clamp(v, 0, 255))
		end
	elseif mode == 2 then -- VE
		local v0, v1, v2, v3 = avg3(tl, a0, a1), avg3(a0, a1, a2), avg3(a1, a2, a3), avg3(a2, a3, a4)
		for y = 0, 3 do
			local q = o + y * 24
			writeu8(S, q, v0)
			writeu8(S, q + 1, v1)
			writeu8(S, q + 2, v2)
			writeu8(S, q + 3, v3)
		end
	elseif mode == 3 then -- HE
		buffer.fill(S, o, avg3(tl, l0, l1), 4)
		buffer.fill(S, o + 24, avg3(l0, l1, l2), 4)
		buffer.fill(S, o + 48, avg3(l1, l2, l3), 4)
		buffer.fill(S, o + 72, avg3(l2, l3, l3), 4)
	elseif mode == 4 then -- LD (d45e)
		writeu8(S, o + 0, avg3(a0, a1, a2))
		local v = avg3(a1, a2, a3)
		writeu8(S, o + 1, v)
		writeu8(S, o + 24, v)
		v = avg3(a2, a3, a4)
		writeu8(S, o + 2, v)
		writeu8(S, o + 25, v)
		writeu8(S, o + 48, v)
		v = avg3(a3, a4, a5)
		writeu8(S, o + 3, v)
		writeu8(S, o + 26, v)
		writeu8(S, o + 49, v)
		writeu8(S, o + 72, v)
		v = avg3(a4, a5, a6)
		writeu8(S, o + 27, v)
		writeu8(S, o + 50, v)
		writeu8(S, o + 73, v)
		v = avg3(a5, a6, a7)
		writeu8(S, o + 51, v)
		writeu8(S, o + 74, v)
		writeu8(S, o + 75, avg3(a6, a7, a7))
	elseif mode == 5 then -- RD (d135)
		writeu8(S, o + 72, avg3(l1, l2, l3))
		local v = avg3(l0, l1, l2)
		writeu8(S, o + 73, v)
		writeu8(S, o + 48, v)
		v = avg3(tl, l0, l1)
		writeu8(S, o + 74, v)
		writeu8(S, o + 49, v)
		writeu8(S, o + 24, v)
		v = avg3(a0, tl, l0)
		writeu8(S, o + 75, v)
		writeu8(S, o + 50, v)
		writeu8(S, o + 25, v)
		writeu8(S, o + 0, v)
		v = avg3(a1, a0, tl)
		writeu8(S, o + 51, v)
		writeu8(S, o + 26, v)
		writeu8(S, o + 1, v)
		v = avg3(a2, a1, a0)
		writeu8(S, o + 27, v)
		writeu8(S, o + 2, v)
		writeu8(S, o + 3, avg3(a3, a2, a1))
	elseif mode == 6 then -- VR (d117)
		local v = avg2(tl, a0)
		writeu8(S, o + 0, v)
		writeu8(S, o + 49, v)
		v = avg2(a0, a1)
		writeu8(S, o + 1, v)
		writeu8(S, o + 50, v)
		v = avg2(a1, a2)
		writeu8(S, o + 2, v)
		writeu8(S, o + 51, v)
		writeu8(S, o + 3, avg2(a2, a3))
		writeu8(S, o + 72, avg3(l2, l1, l0))
		writeu8(S, o + 48, avg3(l1, l0, tl))
		v = avg3(l0, tl, a0)
		writeu8(S, o + 24, v)
		writeu8(S, o + 73, v)
		v = avg3(tl, a0, a1)
		writeu8(S, o + 25, v)
		writeu8(S, o + 74, v)
		v = avg3(a0, a1, a2)
		writeu8(S, o + 26, v)
		writeu8(S, o + 75, v)
		writeu8(S, o + 27, avg3(a1, a2, a3))
	elseif mode == 7 then -- VL (d63e)
		writeu8(S, o + 0, avg2(a0, a1))
		local v = avg2(a1, a2)
		writeu8(S, o + 1, v)
		writeu8(S, o + 48, v)
		v = avg2(a2, a3)
		writeu8(S, o + 2, v)
		writeu8(S, o + 49, v)
		v = avg2(a3, a4)
		writeu8(S, o + 3, v)
		writeu8(S, o + 50, v)
		writeu8(S, o + 51, avg3(a4, a5, a6))
		writeu8(S, o + 24, avg3(a0, a1, a2))
		v = avg3(a1, a2, a3)
		writeu8(S, o + 25, v)
		writeu8(S, o + 72, v)
		v = avg3(a2, a3, a4)
		writeu8(S, o + 26, v)
		writeu8(S, o + 73, v)
		v = avg3(a3, a4, a5)
		writeu8(S, o + 27, v)
		writeu8(S, o + 74, v)
		writeu8(S, o + 75, avg3(a5, a6, a7))
	elseif mode == 8 then -- HD (d153)
		local v = avg2(l0, tl)
		writeu8(S, o + 0, v)
		writeu8(S, o + 26, v)
		v = avg2(l1, l0)
		writeu8(S, o + 24, v)
		writeu8(S, o + 50, v)
		v = avg2(l2, l1)
		writeu8(S, o + 48, v)
		writeu8(S, o + 74, v)
		writeu8(S, o + 72, avg2(l3, l2))
		writeu8(S, o + 3, avg3(a0, a1, a2))
		writeu8(S, o + 2, avg3(tl, a0, a1))
		v = avg3(l0, tl, a0)
		writeu8(S, o + 1, v)
		writeu8(S, o + 27, v)
		v = avg3(l1, l0, tl)
		writeu8(S, o + 25, v)
		writeu8(S, o + 51, v)
		v = avg3(l2, l1, l0)
		writeu8(S, o + 49, v)
		writeu8(S, o + 75, v)
		writeu8(S, o + 73, avg3(l3, l2, l1))
	else -- HU (d207)
		writeu8(S, o + 0, avg2(l0, l1))
		local v = avg2(l1, l2)
		writeu8(S, o + 2, v)
		writeu8(S, o + 24, v)
		v = avg2(l2, l3)
		writeu8(S, o + 26, v)
		writeu8(S, o + 48, v)
		writeu8(S, o + 1, avg3(l0, l1, l2))
		v = avg3(l1, l2, l3)
		writeu8(S, o + 3, v)
		writeu8(S, o + 25, v)
		v = avg3(l2, l3, l3)
		writeu8(S, o + 27, v)
		writeu8(S, o + 49, v)
		writeu8(S, o + 51, l3)
		writeu8(S, o + 50, l3)
		writeu8(S, o + 72, l3)
		writeu8(S, o + 73, l3)
		writeu8(S, o + 74, l3)
		writeu8(S, o + 75, l3)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- inter prediction

local Win = buffer.create(32 * 32)
local FData = table.create(21 * 16, 0)

-- the w x h block at (bx, by) of dst, predicted from src (a plane sw x sh) moved by (mvr, mvc) in 1/8 pixels
local function predict(src, sw, sh, dst, bx, by, w, h, mvr, mvc, bilinear)
	local ix, iy = bx + mvc // 8, by + mvr // 8
	local fx, fy = mvc % 8, mvr % 8
	local sb, base, ss
	if ix >= 2 and iy >= 2 and ix + w + 2 < sw and iy + h + 2 < sh then
		sb, base, ss = src, iy * sw + ix, sw
	else
		-- (beyond the picture's edge: its outermost pixels repeated)
		for r = 0, h + 4 do
			local yy = iy - 2 + r
			yy = math.clamp(yy, 0, sh - 1)
			local so = yy * sw
			local wo = r * 32
			for c = 0, w + 4 do
				local xx = ix - 2 + c
				xx = math.clamp(xx, 0, sw - 1)
				writeu8(Win, wo + c, readu8(src, so + xx))
			end
		end
		sb, base, ss = Win, 2 * 32 + 2, 32
	end
	local d0 = by * sw + bx
	if fx == 0 and fy == 0 then
		for r = 0, h - 1 do
			buffer.copy(dst, d0 + r * sw, sb, base + r * ss, w)
		end
		return
	end
	if bilinear then
		local h0, h1 = 128 - fx * 16, fx * 16
		local v0, v1 = 128 - fy * 16, fy * 16
		for r = 0, h do
			local so = base + r * ss
			local fo = r * 16
			for c = 0, w - 1 do
				FData[fo + c + 1] = (readu8(sb, so + c) * h0 + readu8(sb, so + c + 1) * h1 + 64) // 128
			end
		end
		for r = 0, h - 1 do
			local fo = r * 16
			local dd = d0 + r * sw
			for c = 0, w - 1 do
				writeu8(dst, dd + c, (FData[fo + c + 1] * v0 + FData[fo + 16 + c + 1] * v1 + 64) // 128)
			end
		end
		return
	end
	local H, V = SIXTAP[fx], SIXTAP[fy]
	local h0, h1, h2, h3, h4, h5 = H[1], H[2], H[3], H[4], H[5], H[6]
	local v0, v1, v2, v3, v4, v5 = V[1], V[2], V[3], V[4], V[5], V[6]
	if fy == 0 then
		for r = 0, h - 1 do
			local so = base + r * ss
			local dd = d0 + r * sw
			for c = 0, w - 1 do
				local s = so + c
				local v = (readu8(sb, s - 2) * h0 + readu8(sb, s - 1) * h1 + readu8(sb, s) * h2 + readu8(sb, s + 1) * h3
					+ readu8(sb, s + 2) * h4 + readu8(sb, s + 3) * h5 + 64) // 128
				writeu8(dst, dd + c, math.clamp(v, 0, 255))
			end
		end
		return
	end
	if fx == 0 then
		for r = 0, h - 1 do
			local so = base + r * ss
			local dd = d0 + r * sw
			for c = 0, w - 1 do
				local s = so + c
				local v = (readu8(sb, s - 2 * ss) * v0 + readu8(sb, s - ss) * v1 + readu8(sb, s) * v2 + readu8(sb, s + ss) * v3
					+ readu8(sb, s + 2 * ss) * v4 + readu8(sb, s + 3 * ss) * v5 + 64) // 128
				writeu8(dst, dd + c, math.clamp(v, 0, 255))
			end
		end
		return
	end
	for r = 0, h + 4 do
		local so = base + (r - 2) * ss
		local fo = r * 16
		for c = 0, w - 1 do
			local s = so + c
			local v = (readu8(sb, s - 2) * h0 + readu8(sb, s - 1) * h1 + readu8(sb, s) * h2 + readu8(sb, s + 1) * h3
				+ readu8(sb, s + 2) * h4 + readu8(sb, s + 3) * h5 + 64) // 128
			FData[fo + c + 1] = math.clamp(v, 0, 255)
		end
	end
	for r = 0, h - 1 do
		local fo = r * 16 + 1
		local dd = d0 + r * sw
		for c = 0, w - 1 do
			local f = fo + c
			local v = (FData[f] * v0 + FData[f + 16] * v1 + FData[f + 32] * v2 + FData[f + 48] * v3 + FData[f + 64] * v4
				+ FData[f + 80] * v5 + 64) // 128
			writeu8(dst, dd + c, math.clamp(v, 0, 255))
		end
	end
end

-- a chroma vector: the luma one halved, rounding away from zero
local function halfMv(v)
	if v >= 0 then
		return (v + 1) // 2
	end
	return -((1 - v) // 2)
end
-- the average of four luma vectors (summed), rounding away from zero
local function quarterSum(s)
	if s >= 0 then
		return (s + 4) // 8
	end
	return -((4 - s) // 8)
end

------------------------------------------------------------------------------------------------------------------------
-- loop filter

local function sc(t)
	return math.clamp(t, -128, 127)
end

-- normal filter across an edge: n pixels at off, off + along, ...; `across` steps over the edge
local function lfInner(buf: buffer, off: number, across: number, along: number, n: number, E: number, I: number, hevT: number)
	for k = 0, n - 1 do
		local o = off + k * along
		local p3, p2, p1, p0 = readu8(buf, o - 4 * across), readu8(buf, o - 3 * across), readu8(buf, o - 2 * across), readu8(buf, o - across)
		local q0, q1, q2, q3 = readu8(buf, o), readu8(buf, o + across), readu8(buf, o + 2 * across), readu8(buf, o + 3 * across)
		if math.abs(p3 - p2) <= I and math.abs(p2 - p1) <= I and math.abs(p1 - p0) <= I and math.abs(q1 - q0) <= I
			and math.abs(q2 - q1) <= I and math.abs(q3 - q2) <= I and math.abs(p0 - q0) * 2 + math.abs(p1 - q1) // 2 <= E then
			local ps1, ps0, qs0, qs1 = p1 - 128, p0 - 128, q0 - 128, q1 - 128
			if math.abs(p1 - p0) > hevT or math.abs(q1 - q0) > hevT then
				local f = math.clamp(math.clamp(ps1 - qs1, -128, 127) + 3 * (qs0 - ps0), -128, 127)
				local f1 = math.clamp(f + 4, -128, 127) // 8
				local f2 = math.clamp(f + 3, -128, 127) // 8
				writeu8(buf, o, math.clamp(qs0 - f1, -128, 127) + 128)
				writeu8(buf, o - across, math.clamp(ps0 + f2, -128, 127) + 128)
			else
				local f = math.clamp(3 * (qs0 - ps0), -128, 127)
				local f1 = math.clamp(f + 4, -128, 127) // 8
				local f2 = math.clamp(f + 3, -128, 127) // 8
				writeu8(buf, o, math.clamp(qs0 - f1, -128, 127) + 128)
				writeu8(buf, o - across, math.clamp(ps0 + f2, -128, 127) + 128)
				local a = (f1 + 1) // 2
				writeu8(buf, o + across, math.clamp(qs1 - a, -128, 127) + 128)
				writeu8(buf, o - 2 * across, math.clamp(ps1 + a, -128, 127) + 128)
			end
		end
	end
end

local function lfMb(buf: buffer, off: number, across: number, along: number, n: number, E: number, I: number, hevT: number)
	for k = 0, n - 1 do
		local o = off + k * along
		local p3, p2, p1, p0 = readu8(buf, o - 4 * across), readu8(buf, o - 3 * across), readu8(buf, o - 2 * across), readu8(buf, o - across)
		local q0, q1, q2, q3 = readu8(buf, o), readu8(buf, o + across), readu8(buf, o + 2 * across), readu8(buf, o + 3 * across)
		if math.abs(p3 - p2) <= I and math.abs(p2 - p1) <= I and math.abs(p1 - p0) <= I and math.abs(q1 - q0) <= I
			and math.abs(q2 - q1) <= I and math.abs(q3 - q2) <= I and math.abs(p0 - q0) * 2 + math.abs(p1 - q1) // 2 <= E then
			local ps2, ps1, ps0 = p2 - 128, p1 - 128, p0 - 128
			local qs0, qs1, qs2 = q0 - 128, q1 - 128, q2 - 128
			local f = math.clamp(math.clamp(ps1 - qs1, -128, 127) + 3 * (qs0 - ps0), -128, 127)
			if math.abs(p1 - p0) > hevT or math.abs(q1 - q0) > hevT then
				local f1 = math.clamp(f + 4, -128, 127) // 8
				local f2 = math.clamp(f + 3, -128, 127) // 8
				writeu8(buf, o, math.clamp(qs0 - f1, -128, 127) + 128)
				writeu8(buf, o - across, math.clamp(ps0 + f2, -128, 127) + 128)
			else
				local u = math.clamp((63 + f * 27) // 128, -128, 127)
				writeu8(buf, o, math.clamp(qs0 - u, -128, 127) + 128)
				writeu8(buf, o - across, math.clamp(ps0 + u, -128, 127) + 128)
				u = math.clamp((63 + f * 18) // 128, -128, 127)
				writeu8(buf, o + across, math.clamp(qs1 - u, -128, 127) + 128)
				writeu8(buf, o - 2 * across, math.clamp(ps1 + u, -128, 127) + 128)
				u = math.clamp((63 + f * 9) // 128, -128, 127)
				writeu8(buf, o + 2 * across, math.clamp(qs2 - u, -128, 127) + 128)
				writeu8(buf, o - 3 * across, math.clamp(ps2 + u, -128, 127) + 128)
			end
		end
	end
end

local function lfSimple(buf, off, across, along, E)
	for k = 0, 15 do
		local o = off + k * along
		local p1, p0, q0, q1 = readu8(buf, o - 2 * across), readu8(buf, o - across), readu8(buf, o), readu8(buf, o + across)
		if math.abs(p0 - q0) * 2 + math.abs(p1 - q1) // 2 <= E then
			local f = sc(p1 - q1)
			f = sc(f + 3 * (q0 - p0))
			local f1 = sc(f + 4) // 8
			writeu8(buf, o, sc(q0 - 128 - f1) + 128)
			local f2 = sc(f + 3) // 8
			writeu8(buf, o - across, sc(p0 - 128 + f2) + 128)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- reconstruction

local cur -- the frame being decoded
local refs = {} -- [1] last, [2] golden, [3] altref
local dq -- dequant factors of the macroblock's segment: { y1dc, y1ac, y2dc, y2ac, uvdc, uvac }
local bilinear, fullPixel

local function buildB(mi, x0, y0, aw, mbRow, mbCol)
	local Y = cur.Y
	edges(Y, aw, x0, y0, 16, 4, aw)
	-- S: the row above (with above-left and above-right), the column left, the above-right again at rows 3, 7, 11
	for i = 0, 20 do
		writeu8(S, i, A[i + 1])
	end
	for r = 0, 15 do
		writeu8(S, (r + 1) * 24, Lf[r + 1])
	end
	for _, r in ipairs({ 3, 7, 11 }) do
		for i = 0, 3 do
			writeu8(S, (r + 1) * 24 + 17 + i, A[18 + i])
		end
	end
	local bb = (mi - 1) * 16
	local skip = miSkip[mi] == 1
	local y1dc, y1ac = dq[1], dq[2]
	for b = 0, 15 do
		local bx, by = band(b, 3) * 4, rshift(b, 2) * 4
		predict4(bx, by, bMode[bb + b + 1])
		if not skip then
			local eob = eobs[b + 1]
			if eob > 0 then
				residual(S, (by + 1) * 24 + bx + 1, 24, b * 16, eob, y1dc, y1ac)
			end
		end
	end
	for r = 0, 15 do
		buffer.copy(Y, (y0 + r) * aw + x0, S, (r + 1) * 24 + 1, 16)
	end
end

local function predictInter(mi, x0, y0)
	local ref = refs[miRef[mi]]
	local aw, ah = cur.aw, cur.ah
	local cw, ch = aw // 2, ah // 2
	local cx, cy = x0 // 2, y0 // 2
	if miMode[mi] ~= SPLITMV then
		local mr, mc = miMvR[mi], miMvC[mi]
		predict(ref.Y, aw, ah, cur.Y, x0, y0, 16, 16, mr, mc, bilinear)
		local cr, cc = halfMv(mr), halfMv(mc)
		if fullPixel then
			cr, cc = cr - cr % 8, cc - cc % 8
		end
		predict(ref.U, cw, ch, cur.U, cx, cy, 8, 8, cr, cc, bilinear)
		predict(ref.V, cw, ch, cur.V, cx, cy, 8, 8, cr, cc, bilinear)
		return
	end
	local bb = (mi - 1) * 16
	if miPart[mi] < 3 then
		for _, b in ipairs({ 0, 2, 8, 10 }) do
			predict(ref.Y, aw, ah, cur.Y, x0 + band(b, 3) * 4, y0 + rshift(b, 2) * 4, 8, 8, bMvR[bb + b + 1], bMvC[bb + b + 1], bilinear)
		end
	else
		for b = 0, 15, 2 do
			local r0, c0 = bMvR[bb + b + 1], bMvC[bb + b + 1]
			local r1, c1 = bMvR[bb + b + 2], bMvC[bb + b + 2]
			local bx, by = x0 + band(b, 3) * 4, y0 + rshift(b, 2) * 4
			if r0 == r1 and c0 == c1 then
				predict(ref.Y, aw, ah, cur.Y, bx, by, 8, 4, r0, c0, bilinear)
			else
				predict(ref.Y, aw, ah, cur.Y, bx, by, 4, 4, r0, c0, bilinear)
				predict(ref.Y, aw, ah, cur.Y, bx + 4, by, 4, 4, r1, c1, bilinear)
			end
		end
	end
	-- chroma: each 4x4 takes the average of its four luma blocks' vectors
	local ur, uc = {}, {}
	for i = 0, 1 do
		for j = 0, 1 do
			local y = bb + i * 8 + j * 2 + 1
			local sr = bMvR[y] + bMvR[y + 1] + bMvR[y + 4] + bMvR[y + 5]
			local scc = bMvC[y] + bMvC[y + 1] + bMvC[y + 4] + bMvC[y + 5]
			local r, c = quarterSum(sr), quarterSum(scc)
			if fullPixel then
				r, c = r - r % 8, c - c % 8
			end
			ur[i * 2 + j + 1], uc[i * 2 + j + 1] = r, c
		end
	end
	for i = 0, 1 do
		local k = i * 2 + 1
		local by = cy + i * 4
		for _, pl in ipairs({ "U", "V" }) do
			local sp, dp = ref[pl], cur[pl]
			if ur[k] == ur[k + 1] and uc[k] == uc[k + 1] then
				predict(sp, cw, ch, dp, cx, by, 8, 4, ur[k], uc[k], bilinear)
			else
				predict(sp, cw, ch, dp, cx, by, 4, 4, ur[k], uc[k], bilinear)
				predict(sp, cw, ch, dp, cx + 4, by, 4, 4, ur[k + 1], uc[k + 1], bilinear)
			end
		end
	end
end

local function reconstruct(mi, mbRow, mbCol)
	local aw = cur.aw
	local cw = aw // 2
	local x0, y0 = mbCol * 16, mbRow * 16
	local mode = miMode[mi]
	local is4x4 = mode == B_PRED or mode == SPLITMV
	-- tokens
	if miSkip[mi] == 1 then
		local a = mbCol * 9
		for k = 1, 8 do
			aboveCtx[a + k] = 0
			leftCtx[k] = 0
		end
		if not is4x4 then
			aboveCtx[a + 9] = 0
			leftCtx[9] = 0
		end
	else
		local total = decodeTokens(mbCol, is4x4)
		miSkip[mi] = total == 0 and 1 or 0
	end
	local skip = miSkip[mi] == 1
	-- prediction
	if miRef[mi] == 0 then
		local U, V = cur.U, cur.V
		local cx, cy = x0 // 2, y0 // 2
		local uv = miUv[mi]
		edges(U, cw, cx, cy, 8, 0, cw)
		predictMb(U, cw, cx, cy, 8, uv, mbRow > 0, mbCol > 0)
		edges(V, cw, cx, cy, 8, 0, cw)
		predictMb(V, cw, cx, cy, 8, uv, mbRow > 0, mbCol > 0)
		if mode == B_PRED then
			buildB(mi, x0, y0, aw, mbRow, mbCol)
		else
			edges(cur.Y, aw, x0, y0, 16, 0, aw)
			predictMb(cur.Y, aw, x0, y0, 16, mode, mbRow > 0, mbCol > 0)
		end
	else
		predictInter(mi, x0, y0)
	end
	if skip then
		return
	end
	-- residual
	if mode ~= B_PRED then
		local Y = cur.Y
		local dcq, acq = dq[1], dq[2]
		if mode ~= SPLITMV then
			inverseWalsh(eobs[25], dq[3], dq[4])
			dcq = 1
		end
		for b = 0, 15 do
			residual(Y, (y0 + band(b, 3) * 0 + rshift(b, 2) * 4) * aw + x0 + band(b, 3) * 4, aw, b * 16, eobs[b + 1], dcq, acq)
		end
	end
	local cx, cy = x0 // 2, y0 // 2
	local uvdc, uvac = dq[5], dq[6]
	for b = 16, 23 do
		local plane = b < 20 and cur.U or cur.V
		local k = b < 20 and b - 16 or b - 20
		residual(plane, (cy + rshift(k, 1) * 4) * cw + cx + band(k, 1) * 4, cw, b * 16, eobs[b + 1], uvdc, uvac)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- the loop filter over the whole frame (after all of it is decoded: prediction inside the frame uses the unfiltered
-- picture)

local function loopFilter(self, keyFrame, filterType, level, sharpness)
	-- each segment's / reference's / mode's level
	local lvl = {}
	for seg = 0, 3 do
		local ls = level
		if self.segEnabled then
			ls = self.segAbs and self.segLf[seg] or level + self.segLf[seg]
			ls = math.clamp(ls, 0, 63)
		end
		local t = {}
		for ref = 0, 3 do
			t[ref] = {}
			for m = 0, 3 do
				local v = ls
				if self.lfDeltaEnabled then
					v = ls + self.refDeltas[ref]
					if ref == 0 then
						if m == 0 then
							v += self.modeDeltas[0]
						end
					else
						v += self.modeDeltas[m]
					end
					v = math.clamp(v, 0, 63)
				end
				t[ref][m] = v
			end
		end
		lvl[seg] = t
	end
	local Y, U, V = cur.Y, cur.U, cur.V
	local aw = cur.aw
	local cw = aw // 2
	for mbRow = 0, mbRows - 1 do
		for mbCol = 0, mbCols - 1 do
			local mi = (mbRow + 1) * miStride + mbCol + 2
			local mode = miMode[mi]
			local L = lvl[miSeg[mi]][miRef[mi]][MODE_LF[mode]]
			if L > 0 then
				local inner = mode == B_PRED or mode == SPLITMV or miSkip[mi] == 0
				local I = L
				if sharpness > 0 then
					I = rshift(I, 1)
					if sharpness > 4 then
						I = rshift(I, 1)
					end
					if I > 9 - sharpness then
						I = 9 - sharpness
					end
				end
				if I < 1 then
					I = 1
				end
				local bE, mbE = 2 * L + I, 2 * (L + 2) + I
				local hevT
				if keyFrame then
					hevT = L >= 40 and 2 or (L >= 15 and 1 or 0)
				else
					hevT = L >= 40 and 3 or (L >= 20 and 2 or (L >= 15 and 1 or 0))
				end
				local yo = mbRow * 16 * aw + mbCol * 16
				local co = mbRow * 8 * cw + mbCol * 8
				if filterType == 0 then
					if mbCol > 0 then
						lfMb(Y, yo, 1, aw, 16, mbE, I, hevT)
						lfMb(U, co, 1, cw, 8, mbE, I, hevT)
						lfMb(V, co, 1, cw, 8, mbE, I, hevT)
					end
					if inner then
						lfInner(Y, yo + 4, 1, aw, 16, bE, I, hevT)
						lfInner(Y, yo + 8, 1, aw, 16, bE, I, hevT)
						lfInner(Y, yo + 12, 1, aw, 16, bE, I, hevT)
						lfInner(U, co + 4, 1, cw, 8, bE, I, hevT)
						lfInner(V, co + 4, 1, cw, 8, bE, I, hevT)
					end
					if mbRow > 0 then
						lfMb(Y, yo, aw, 1, 16, mbE, I, hevT)
						lfMb(U, co, cw, 1, 8, mbE, I, hevT)
						lfMb(V, co, cw, 1, 8, mbE, I, hevT)
					end
					if inner then
						lfInner(Y, yo + 4 * aw, aw, 1, 16, bE, I, hevT)
						lfInner(Y, yo + 8 * aw, aw, 1, 16, bE, I, hevT)
						lfInner(Y, yo + 12 * aw, aw, 1, 16, bE, I, hevT)
						lfInner(U, co + 4 * cw, cw, 1, 8, bE, I, hevT)
						lfInner(V, co + 4 * cw, cw, 1, 8, bE, I, hevT)
					end
				else
					if mbCol > 0 then
						lfSimple(Y, yo, 1, aw, mbE)
					end
					if inner then
						lfSimple(Y, yo + 4, 1, aw, bE)
						lfSimple(Y, yo + 8, 1, aw, bE)
						lfSimple(Y, yo + 12, 1, aw, bE)
					end
					if mbRow > 0 then
						lfSimple(Y, yo, aw, 1, mbE)
					end
					if inner then
						lfSimple(Y, yo + 4 * aw, aw, 1, bE)
						lfSimple(Y, yo + 8 * aw, aw, 1, bE)
						lfSimple(Y, yo + 12 * aw, aw, 1, bE)
					end
				end
			end
		end
		breathe()
	end
end

------------------------------------------------------------------------------------------------------------------------
-- frames

local function dequantFactors(q, d)
	local function at(t, i)
		return t[(math.clamp(i, 0, 127)) + 1]
	end
	local y2ac = at(T.AC_Q, q + d.y2ac) * 101581 // 65536
	return {
		at(T.DC_Q, q + d.y1dc), at(T.AC_Q, q), at(T.DC_Q, q + d.y2dc) * 2, y2ac < 8 and 8 or y2ac,
		math.min(at(T.DC_Q, q + d.uvdc), 132), at(T.AC_Q, q + d.uvac),
	}
end

-- one frame; returns the frame it shows, or nil
function Decoder:decodeFrame(buf, pos, size)
	if size == 0 then
		return nil -- (a dropped frame: the last picture stays)
	end
	if size < 3 then
		fail("the frame is cut off")
	end
	local stop = pos + size
	local b0, b1, b2 = readu8(buf, pos), readu8(buf, pos + 1), readu8(buf, pos + 2)
	local keyFrame = band(b0, 1) == 0
	local version = band(rshift(b0, 1), 7)
	local show = band(b0, 16) ~= 0
	local firstSize = rshift(b0 + b1 * 256 + b2 * 65536, 5)
	pos += 3
	if keyFrame then
		if stop - pos < 7 then
			fail("the key frame's header is cut off")
		end
		if readu8(buf, pos) ~= 0x9d or readu8(buf, pos + 1) ~= 0x01 or readu8(buf, pos + 2) ~= 0x2a then
			fail("broken data (key frame sync code)")
		end
		local w = band(readu8(buf, pos + 3) + readu8(buf, pos + 4) * 256, 0x3fff)
		local h = band(readu8(buf, pos + 5) + readu8(buf, pos + 6) * 256, 0x3fff)
		pos += 7
		self:setSize(w, h)
	elseif not self.haveKey then
		fail("the video does not start with a key frame")
	end
	if firstSize == 0 or pos + firstSize > stop then
		fail("the frame is cut off (first partition)")
	end
	bilinear = version ~= 0
	fullPixel = version == 3

	-- frame state
	D = self
	miMode, miUv, miRef, miMvR, miMvC = self.miMode, self.miUv, self.miRef, self.miMvR, self.miMvC
	miSeg, miSkip, miPart, bMode, bMvR, bMvC = self.miSeg, self.miSkip, self.miPart, self.bMode, self.bMvR, self.bMvC
	miStride, mbCols, mbRows = self.miStride, self.mbCols, self.mbRows
	aboveCtx = self.aboveCtx

	if keyFrame then
		self.mvProb = table.clone(T.MV_DEFAULT)
		self.ymodeProb = table.clone(YMODE_PROB)
		self.uvModeProb = table.clone(UV_MODE_PROB)
		self.coef = defaultCoefProbs()
		self.segAbs = false
		for i = 0, 3 do
			self.segQ[i], self.segLf[i] = 0, 0
			self.refDeltas[i], self.modeDeltas[i] = 0, 0
		end
		self.signBias[2], self.signBias[3] = 0, 0
	end

	bStart(buf, pos, stop - pos)
	if keyFrame then
		bRead(128) -- (colour space)
		bRead(128) -- (clamping)
	end
	-- segmentation
	self.segEnabled = bRead(128) == 1
	local updateMap = false
	if self.segEnabled then
		updateMap = bRead(128) == 1
		local updateData = bRead(128) == 1
		if updateData then
			self.segAbs = bRead(128) == 1
			for i = 0, 3 do
				self.segQ[i] = bRead(128) == 1 and bSigned(7) or 0
			end
			for i = 0, 3 do
				self.segLf[i] = bRead(128) == 1 and bSigned(6) or 0
			end
		end
		if updateMap then
			for i = 1, 3 do
				self.segTree[i] = bRead(128) == 1 and bLiteral(8) or 255
			end
		end
	end
	-- loop filter
	local filterType = bRead(128)
	local filterLevel = bLiteral(6)
	local sharpness = bLiteral(3)
	self.lfDeltaEnabled = bRead(128) == 1
	if self.lfDeltaEnabled and bRead(128) == 1 then
		for i = 0, 3 do
			if bRead(128) == 1 then
				self.refDeltas[i] = bSigned(6)
			end
		end
		for i = 0, 3 do
			if bRead(128) == 1 then
				self.modeDeltas[i] = bSigned(6)
			end
		end
	end
	-- token partitions
	local nParts = lshift(1, bLiteral(2))
	local sizesAt = pos + firstSize
	local p = sizesAt + 3 * (nParts - 1)
	if p > stop then
		fail("the frame is cut off (partition sizes)")
	end
	local parts = {}
	for i = 0, nParts - 1 do
		local sz
		if i < nParts - 1 then
			local q = sizesAt + i * 3
			sz = readu8(buf, q) + readu8(buf, q + 1) * 256 + readu8(buf, q + 2) * 65536
		else
			sz = stop - p
		end
		if sz < 0 or p + sz > stop then
			fail("the frame is cut off (partition)")
		end
		parts[i + 1] = { p, sz }
		p += sz
	end
	-- quantizers
	local q = bLiteral(7)
	local dqd = {}
	for _, k in ipairs({ "y1dc", "y2dc", "y2ac", "uvdc", "uvac" }) do
		dqd[k] = bRead(128) == 1 and bSigned(4) or 0
	end
	local segDq = {}
	for seg = 0, 3 do
		local sq = q
		if self.segEnabled then
			sq = self.segAbs and self.segQ[seg] or q + self.segQ[seg]
			sq = math.clamp(sq, 0, 127)
		end
		segDq[seg] = dequantFactors(sq, dqd)
	end
	-- references
	local refreshGolden, refreshAlt, copyGf, copyArf = true, true, 0, 0
	if not keyFrame then
		refreshGolden = bRead(128) == 1
		refreshAlt = bRead(128) == 1
		if not refreshGolden then
			copyGf = bLiteral(2)
		end
		if not refreshAlt then
			copyArf = bLiteral(2)
		end
		self.signBias[2] = bRead(128)
		self.signBias[3] = bRead(128)
	end
	local refreshProbs = bRead(128) == 1
	local saved
	if not refreshProbs then
		saved = { table.clone(self.coef), table.clone(self.ymodeProb), table.clone(self.uvModeProb), table.clone(self.mvProb) }
	end
	local refreshLast = keyFrame or bRead(128) == 1
	-- coefficient probability updates
	local C = self.coef
	local UP = T.COEF_UPDATE
	for i = 1, 1056 do
		if bRead(UP[i]) == 1 then
			C[i] = bLiteral(8)
		end
	end
	COEF = C
	-- modes
	local skipProb = bRead(128) == 1 and bLiteral(8) or nil
	local probIntra, probLast, probGf
	if not keyFrame then
		probIntra = bLiteral(8)
		probLast = bLiteral(8)
		probGf = bLiteral(8)
		if bRead(128) == 1 then
			for i = 1, 4 do
				self.ymodeProb[i] = bLiteral(8)
			end
		end
		if bRead(128) == 1 then
			for i = 1, 3 do
				self.uvModeProb[i] = bLiteral(8)
			end
		end
		local M = self.mvProb
		local MU = T.MV_UPDATE
		for i = 1, 38 do
			if bRead(MU[i]) == 1 then
				local x = bLiteral(7)
				M[i] = x ~= 0 and x * 2 or 1
			end
		end
	end
	mvProb = self.mvProb
	if not keyFrame and not (self.last and self.golden and self.altref) then
		fail("broken data (a missing reference frame)")
	end
	decodeModes(keyFrame, updateMap, skipProb, probIntra, probLast, probGf)

	-- the macroblocks, row by row (each row's tokens from partition row % count)
	cur = self:takeFrame()
	refs[1], refs[2], refs[3] = self.last, self.golden, self.altref
	for i = 1, mbCols * 9 do
		aboveCtx[i] = 0
	end
	local readers = {}
	for i = 1, nParts do
		bStart(buf, parts[i][1], parts[i][2])
		readers[i] = bSave()
	end
	local segEnabled = self.segEnabled
	for mbRow = 0, mbRows - 1 do
		local ri = mbRow % nParts + 1
		bLoad(readers[ri])
		for k = 1, 9 do
			leftCtx[k] = 0
		end
		for mbCol = 0, mbCols - 1 do
			local mi = (mbRow + 1) * miStride + mbCol + 2
			dq = segDq[segEnabled and miSeg[mi] or 0]
			reconstruct(mi, mbRow, mbCol)
		end
		readers[ri] = bSave()
		breathe()
	end
	if filterLevel > 0 then
		loopFilter(self, keyFrame, filterType, filterLevel, sharpness)
	end

	if saved then
		self.coef, self.ymodeProb, self.uvModeProb, self.mvProb = saved[1], saved[2], saved[3], saved[4]
	end
	-- references
	local new = cur
	if copyArf == 1 then
		self.altref = self.last
	elseif copyArf == 2 then
		self.altref = self.golden
	end
	if copyGf == 1 then
		self.golden = self.last
	elseif copyGf == 2 then
		self.golden = self.altref
	end
	if refreshGolden then
		self.golden = new
	end
	if refreshAlt then
		self.altref = new
	end
	if refreshLast then
		self.last = new
	end
	if keyFrame then
		self.haveKey = true
	end
	cur, refs[1], refs[2], refs[3] = nil, nil, nil, nil
	return show and new or nil
end

-- one frame at a time in a Luau VM: the decoding state lives in this module, and a frame pauses midway (breathe), so a
-- second decoder (another import worker in the same VM) waits for the frame being made to finish
local holder
local function decodeLocked(fn, ...)
	local me = coroutine.running()
	if task then
		while holder and holder ~= me and coroutine.status(holder) ~= "dead" do
			task.wait()
		end
	end
	holder = me
	local ok, pic = pcall(fn, ...)
	holder = nil
	if not ok then
		error(pic, 0)
	end
	return pic
end

-- one WebM block / IVF frame
function Decoder:decodeSample(buf, pos, len)
	pos = pos or 0
	len = len or buffer.len(buf) - pos
	return decodeLocked(self.decodeFrame, self, buf, pos, len)
end

return Vp8
