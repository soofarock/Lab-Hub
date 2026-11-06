--!native
--!optimize 2
-- Shared gradient shapes for FrameLab strips. Roblox draws only about 1000 DIFFERENT gradients at once (identical
-- ColorSequences are shared), so a strip past the exact-gradient budget is drawn as
--   Frame.BackgroundColor3 = tint (per channel, the brightest the strip gets)  x  UIGradient = one of these shapes
-- (Roblox multiplies the two). A pool of Shapes.Slots shapes, 12 evenly spaced keypoints each (RGB 0..1): it starts as
-- 512 generic shapes learned from strips of several unrelated videos, and shapes no strip uses are replaced by the ones
-- the picture needs. A 2-level index (24 groups) finds the nearest one quickly.
--   Shapes.match(profile) -> slot, distance   profile: 36 numbers, the strip's colours / tint at the 12 keypoints (0..1)
--   Shapes.take(profile, brightest, slot?, distance?) -> slot   (in use until Shapes.drop(slot))
--   Shapes.sequence(slot) -> ColorSequence (shared by every strip that uses it)    Shapes.inUse()    Shapes.P = 12
local EncodingService = game:GetService("EncodingService")
local Shapes = {}
local P, D, N, NC = 12, 36, 512, 24
Shapes.P = P
local LIB = table.concat({
	"OyoiUEE6w7y2////tK2mRTkvKBsWOCsmPzIxPzM0Oy8vPzI16d3hX05IbV1W1dHMyca8em9jPzIoNCggUUU4jYh8nZeJW1RFQS4y",
	"OiwkppuV8fDr3djRZl9VJh4SenJr4dvY6eLje3FuJxoUXklNX01NzMC9/P39vrSuTkM2Sj0uv7at2s7Hbl1SNSAZVj0wnImKVCxM",
	"lHqE8fHj49TbkWeOdj9+i06cmFq0mVi5kk2zlVK0OC4uLychkYyJ6unm397Wb2xiIR0UGhQONjErf31329nU5+biIyIji4uM5uXm",
	"/Pz8hISCGBgWBAMDKigofHp7w8HDta+0MCkvIyEPKSkWcXFf7O7qx83LNjQjYWBQwcG+op2OX1lNTkZEpJyigWY4lHtCx7aL1MSi",
	"4Na97ejTmYNKZUMSyci7zc28XEkclpF4UDoxmoqA+fj45eHchXlpU0U3SzsxRzcuRTMvTzw4YU9Oe2ppNCgwKB4ijoSF/Pv56ebi",
	"iIF8IxsZMignkYmK6uXo1c/RUEhIk36ITj07saWl/Pr54d7Yko18Zl9MkIp/pqGadGteQDMjSToyVz1Jjn+E6OPl+vj5vK6yclxg",
	"YkdOgGVsmH6HpIiSooWNooSLlXuBTDIqnY2E9vPy7enkj4F0PCkdOygfQS8pPiwnQi4mRDIrTUZLn5mb5+jp+vn67+vrm5WTQzg2",
	"X1ZTq6im6evpmpWTLB0cXENQUDw6w7a89vLz29LKmo1+a1xJcmVaWks+NCYdcW1gz9XVNCImWEhIt7Cw8PHy+Pr12NPNk4qDXk1G",
	"Tjk3YUpKfGNohmVvY09MPystX1BOurGu+vj1/Pr6+fT1+PPz9/Py9fHw9fDv8uzsiHHAOCMfd2dR08fM+/Tl/vrI/fek/fWQ/vCE",
	"/u19/Od7+OByIxchGg8XFQwTJh4jioSH7Orq+/r7+vf49/T19/T19/T09vLz8/rzRj8/MyIpxbvC8+Hu59Hh6cbh47/a47ja47na",
	"57zg6L7iVjxGWUBLV0FKQys2Yk5Wx7zB9/b2+fX39e/w8err7+fp7ebo18jKlYSBgXFtuq6r8Oro+PPy+fLz+vP0+fPz+vX0+/f2",
	"+fX1Wk5Hc2lhbGJbdm1ow7679fTz+/j3+vb2+fT2+fT3+fT3+PP3b2NrT0FHOCowSDxBkImN1NDQ6Ofl5eHg5+Ti8/Lyy8bFb2Nk",
	"5dzWj4R9Rzo3ZlpXwbm39PDw+vf4+fT2+fT2+PP29fDz7+ruKiEiRz09ysfE+fn39vPz9O7w9O3v9e3w9e3x9e7y9u/y9O3wAGqL",
	"dGpGRmpGAP8u/4D/0b/R0b/R0b/R0b/R0b/R0b/R0b/RhGtvbVFXbVNYf2Jno4WGvqKix6+qv6SdvKKcyLKx59ze+vn6XkhDZEtL",
	"kX99pZOSo5CRsp6h0cLE7uPl8+/u9vTz8vLw6erocF1iOygwNiMtb2FnycTG9fX19/P18urv7ePo6t/l6t7k5tvhKh0oHBAaIBcc",
	"dGxx4t3f/Pv7+fb2+PT09/T0+PT19/T19vLzp6OXZmBYODEvRT09i4aG2NXV+fj4/Pn7+/f6+vb4+PT35uPlRjU2NyUra19jvrm7",
	"8O/v7ufr3c/XxrK/sJmptZ2u0bvM4tHeraGmZVleZlxfta2u+ff3/Pv7+fT0+fT1+fX2+vX2+vX2+fX1reGuTlRIZVRepqmk+PL2",
	"8+Tw7sjr8cru7c/t7M/t587n38jfgnJwWEZHnI2P5N3d9/Lz+PD09+/z9+/z9+/y9/Lz+PL08uzty8TJNCgtS0BC5eHi/f39+vf4",
	"+vP2+fL1+fDz9ezv8unt8unsOicuW0dP0NLP9fH26tvo48jg3r7a37zb3bfb4Lzd4L/e3sDeu7KTYFM8NCUZfXNn5eDa+fn3+fP2",
	"+O/0+e/0+e/0+O/09OrwHxMaHBIXZ19j2dXV+/r6+PX39vH09vH09/L1+PP2+PP29fDzp9miQUU8aVVlrbKs+/r59/P38M7x37Tg",
	"v5bBsoO0waHEyqzNwKeAc1ZDXUA1oouA8N7i9Ofvz7rGn4iTqZWR3c7A8OvO6eTBvay8fGB4kHiL5eHh8Ozs5+Hh5N3d493a19HS",
	"1dHQ19TT29jbPTMzMiYpY1lbr6qt5uTm9vP29vD09fDy9e/y7OXou7O2bl5mmH+Sn4ebln+Ti3WIppSk2c3X8eju9O7z9e/z9fHz",
	"9vL08/HwVkxCgnxxpKCGsK6Wwryd4d3A9/fkvLKWWkE0ZEw+u6S12cLUUDkkpZiT7ev09PPa8e2r9e2S9uh3+uhs++dg+uFS+uJP",
	"/ORR03x02ndy3W9u4Wxt7Xt87YSG2Xl+rVxillBYsoqS4dXY7/j6UT5Iv7679PP06+Ds38rg07zUy7TNybXMy7rNzLjO0cHS39bg",
	"xMDB7enq6OPjubO1oJiZsKqqzMbGwLa4oZOYsaer29TZ7ufszsfIrqSol4yNo5eZyb/C6eDk9e/vzcXFjIGBin59vrWy6OHcmX9u",
	"2NTD1szAv7Odo499sq2Szcy4saR+no9qqa6Dvb+hk4FXTT5BY1VVwbm17Obj6+bd493T5eHZ2NTNfHNsQTYvnJeV8PDvamBhure6",
	"7evv9fP09vP08u7wzcjIhHt5QjcySj87mJOR2NXXcGNroaCm1dXd4+Tr29fjraWxaFlnSTdCY1Nap5ab3dHQ59zaY1Vbv7q98vDy",
	"9vT19fH0+PP3+fT44tbds6atm42VsqStzsLIblRi2+vJwZG37p3p94/85I/rvqm7f4V3l5ab07/U5JLk8ZbuvL2/op6fraeo4d3f",
	"+PP27+jsxbq9oZSVnI+QraCkx76/w7i8OTEyS0VDnpub4uDd6Ojlw8G/hX99W1NUdG1ut7O16ujq5OHjeHFwk4+Gvbqx1dLI4t7V",
	"8O7lzci/WUtKRTU1taqx8Orw6+Ds083Tz8bOzMPM2tPZ7enr9fPyxrzAX0tZVUJNl4qOqpyjmIeR6uTl9PDx9fDy9/H09/Hz9vHz",
	"4tvcpJedfW50nIyS0cXH6uTinZKY+PD3vrW2XVNSvbWy6eTmpZ6cV1FJRUA50tHL5ubhUlBHj5GH0uPImV+Y5tbU8Zjw+I378475",
	"8K3ysI6weXh1teudm3mUYE5GpZeQ5t7O2s+5opR5kIJonJJ+kYd3V0w/TEAwr6um9/f4q6Oopp+grKanqaafp6KcqKGfq6OjpZyb",
	"ppiar6Gkx7+++vn3hW+Bqp2n1dHV7u7t9fH02czXpImciGh9lXeMn4WSjHB7dVxgkXx96d/X39PMj3tpcFVGm4d2wLKniHRpUjot",
	"fWpiy7696N7e2tPZ7+jt8eru8+zw9vHy7ejqqqSjT0dHWVBMt7Gq7+zi7urgnZmbyMfI8fDz+fn6+fj55+XlvLi2mZWTqqWjwL25",
	"vLi2sKmp2qTY3anb46rU4pfS3J3a36jfxKPGdFRsaVZXvsq44N3iyqm1w7e61cjO08XMzb7G0L/G3tDV7OPnzL/DbFdaQS0sl4uE",
	"5uragHJht6qg6+Pb+PHy9e3w4dfataSpn42PvK2x5t3f9/Hz9/H0RTE3lI6Vva/Cn4akh12KlWuY08DW2svatJqyz8DL8PDt6enk",
	"d0U8fE0iwa6Z8Ovk7urYyrFutIk6waNA5tZ35NNg6tdk8eWGRDU4lZOQ5OTlzcnLopSXtams5+Ti5+Hin5CUcWBiopea3dbcFAgM",
	"EwcLEgcLEwcMFAgMFQkMFwoNFQgKEwcINicq3+Pk/vj7BwMEBwMDBwMDBwMDBwMDCAMDCAMDCQMECgMDCQICEAYH////GBISFhAR",
	"FRARFA8QFhASGBMTFxISGRQSREA7s7Cs8O/u+/n5RDQtNCIbLx4bNycmRzo7T0JERTUzOCQePCYgk4B5/f39vKyeMAMEMAMEMAME",
	"MAMELwMCLwMDLgMCLQMDQQMLOAIEQwIY//L/18vYW0hTJBgbHxoXHxsWHx0XJiUiIyEdIiAcMS4mYmVU3erXOhhVOxhXOxhXOxdX",
	"OxlWOxxVOh9QKxM9GwolPjBCqaKp////OyBIPiBJPiBHPh9EQB5CPyJKQSVKQClIMx45JhYpPzM9//z/indsaFRKTTktQS4iRTMo",
	"RjQpPi0iMyIZOyoggXVp4t3Z9/X1HBIUGxAUGQ4SGA0RGQ4SGg4SGw8SHRIUHBETJBobdm5z////YQAAYQAAYQAAYQAAYQAAYQAA",
	"YQAAYQAAiQAFhAAEkgotygBjPBhYOhVXORVVOBdUNxlRNBpJJxE4EQQcPC1CubC7+Pb49vT20aslx6E2upg/jmEepIhW6Ov11djK",
	"rrKDusOS3ujAjH9GhGsO8uuL9+t79uVl9+VY9+ZR+OhW9+ZY+Ohx9+yq9PDf0sfOZkYctOb/jHVH7NGPxbKRf2En5ualm30iyrRl",
	"//+13c6BelMCqaBK38lC5tQ+7d5B8Nw479o28uBN8ONkzsRbhGcWUS8Hdl9ExcTs9dMu99Yy9s4r99Iq+tgt9tUp4c8nuNUmhskz",
	"Vr1QS7uZGN//6NY49OQ++us8++06+us+9uZK4MtHqIshiWgno4RY07i58+H6695x8OJm8eFU9+hX+ehZ+etn+/Ca+/XF6d/Tpo9Y",
	"Xz4ZYEI66cb6yaTFs5GRw6eK4s6V9uqR+vKE+fJy+PJr9+5h8eZZ5dRL5+j739uS19NX4dhI6N066uI27uQz7OEs7OYz6+Q16uQ7",
	"7elX2cgu3ssq69o379887+A88eE98+NC7t1C69pO5NNk5Nqi4eDw6OAU7egX8usZ8Okc7ucv5+RU6OaR6+XC6OCy4d6vyshZ5uzt",
	"49vn9fHh+PTS+PK69emU7dtt4MlF28Ex58059N1P+uhi+Odr1s3+aVpOQzIRh3o94diX+faf+e54+Ohf+eZS+uRP+eFQ999a8uOR",
	"8tuA06Uz0KEz89d359B5r3oskFUUqo9VzN/TwdvPWzcb3d3iz8O1gF08cUQZrpVZ18iF28t53MZt59aJ49uin388YDMZ1ub/WRcr",
	"azM448147NSAzZ9DqWkZsI5H3NiGr8iJgoZUXXBP9Ov9wbG3aldFRzYWgnEwzMBo7ORy9eli9eZN9+ZG9uRH8t5J08bVdGNlWkhE",
	"r6ii+fnz08/CcmhWOCobLiEWNSgbNSoeOi4h5+PxZVdTTkEwyMO/9/Xt0cu8qKGMn5eCmpeLdXBiRkE3RkE339zsXkdBXks3ysOu",
	"6OXKy7+dmoRha00qYkQsblc4l4hs1s63euYAeswzZswz/4BmuEz/o2bmcP8AiI1mrTNgZswAn7kAwmZAOy00KBsdHxQSSkU5x8DD",
	"+/j6npmUQTkuLyYgLycmLiUoPjQ3YU9WQjEzYVRSwLm29fXx6uvnqKWcSkQ/KyEeSEI+kpOR3+Pg4+HYiX9wSz0vYVRFwbi07+ro",
	"z8O9cmFaMB0WMh4bNSQhMyIhQTg4KSEgT0hGuri4//7+wL69UktJHxgWHxcXIhocJhwgLSQnqZKVV0RDPCspdWpo1NDO+/v52dbX",
	"mZGQbF9cem1nkoSBloiF9fP3lIuJTkI6gHdv2tbN6ubeqZySYE5BRzAoTDIvdVtYqJGOOjc0DAkHGBQSnJmX8/Hy2dfVZWJgLSkm",
	"tbGs8+/soJuWRT88dWZRfWlcYEw7RjIklZCH+fz5rKagVEIwY05AkH9xi3ZpaExBdmVaOSQcW0o1zcS3//72tqyfTzwwOyYkX0lU",
	"dF90fmuJhnOUemxqPzInOC0hZ15SyMXA/v796OXjiYF+Oi4rJhoYIRQYKBwexcbPe3V6NygtWU1Q1cnP+/b4+ff3yb/EbWNnJRYc",
	"OzU8iIuUkXt7XklDc2FSuK+m9PHt4dvNm41zX0wxenBcvLaqfW1aSDEY8/bkX0lcSClMrJS059H1uJPVfkundTylf0Wwg0i1gUax",
	"fUOqJyIcEg0KJCEYnpyV////l5SRNConPTEvdGJooZCXdmVuSDdArYakVCpEXDpJvqO1/vv7rpmdSig0j3V+1cLPpYqXUio9SSQv",
	"9/L3+ff5/Pv8s660Ny06FggfKBY1NhxKOx9SOxlZOhZZPBZe9O7w9/X20cvMcWRmOSgtUEBAeWpminp2emdkXkhIUTo8Uz5AgW94",
	"/PX8lYuLKiUfJiEdJB8eKCUhKygjKiUjLSgmLScnKyUl9PPz9fT0xL/CUUhMFw0TEw0QFBASFREUFhEVFRAUFxEVGhQX6OTn8O7w",
	"7uvtwru/cWZqOy8yKh4gKyAhU0dGnJST0MjF29TR7urp9/XzzcTDeGxtQC80PCo2TTlKYkxie2R/j3STjnCTg2SIkH6D6+jo+fb3",
	"opKRRTApPCkkTTszUT05Ujs3UDs3Tzs3UUI+2tvb5ufnoaCfPDk3GBIRGxcVIBsbHRkZGBMULCcme3p35Obi/vz94tzggXR/MSEy",
	"KRMrPCJERClPRCVUQCFSPR1TPR5UQiRY6N3l8OjvzcLGhHF1UDg+Qi0yTTpAUEBEQTE2MyUlXllUw8q/+fj32tXSdGlkSDkzSTs0",
	"TUA4VEY8ZVdMcWFVbFtPZlZJZ1ZK7ent9PH18vDzq6mtPjJBEg0UEAoREA0PDwsNDQsLDAsLDw4N2+Pf58rtjZ2GPpA2OJIqN5Un",
	"OpgpO5kpO5gmO5cmPJgpN5In8+7x7efq6OPkxby9f25wTTg7SDIzUz49W0VDWEI/V0E8ZVRNUERFwLu4/f39xsK/UktIIRkWHhYT",
	"IRkXJBwbJRwbIRkYJh4efG9jvbWk5+TXpZyPRzw1c2dm0czO8u316+Tv5Nrn5tvo5tzp7uvs9PHy9fT05uTkrKeoWFJTU01NtK+w",
	"9PHx9/T09O/w8evtOigjXExF08u17enUq6OJNiscS0I4zMfA7Ovz6ubw5ePu4uDr4Nrc5N/i6+bp7+rt3NjaoZqffHR5i4OGo52f",
	"yMXE6enl6uvn5d/l4drh7Ojs7ursx77EiHyDhnmBz8jM8O7t087Pn5WXioCCpquutrnCtLG/rqe4p5yvoJalo5aksqGvzcTL8vDw",
	"6+vobFVgY1pZoZyZ7+/q+Pr2wcC8XVZVODAwop2d7Ozp8vHt2tbTq6Wk6OXp7+zw5eDlta6yal9kOCwxPjQ3eXN0xMHA5+fl6enp",
	"4eLizLvB2MfP8Obs3dfXd2dqXExPwr687ePs4tLd0sPNt6mwh3h99uA4+OQ89+VK7NVHwaM0iWcclnZA3MWk+Ovl9+nu7drr4srg",
	"7Obt9vH29/H19vH15uHkmpKTQjg4UEhCrKed6ebZ9fHj9O7fcUJn4svZ8Mns8bf74rTjf415dH5Zx8O95aXj6pvf3s/OXEdX9N/s",
	"+Of279/mw6+dcl4kalYTrJs35NVw+u51/O5t+utl9uZmhXJ5rJmi2cjR7N/nzcDIkIGKc2ZrqZ+i5+Hl9u709ezz8u7x7uTq9+70",
	"8Ojst6qtZlRbYk9XrKGi4tvc7+fs7+bs7+bu7+ftdmVdxL2y5uLZqp+VUUA5Pyopd29uyMjK2N3g0dLa0dPb0tLbva+41MjS39fe",
	"2NHVubG1f3B0QjA0WUlKvLa18vTx6enkr6ekx3G/u2Kzy3XDwWq5hkCBTw9LUy5PnoOe5Nzh+Pj69PL17+3v1c/RxLW+3crX7tnq",
	"4dLcmI2Si4GB3trZ8e7r5dfh5Nng2NjU+O7xnIuRSjg/UEFGlpKTx8vLydDPwMfGv8bGxc3MzNXTy9LQ5uXk5+XklIyLPzMwLCEf",
	"YFlVtrGw4d/f2dPWvra7qZ6llomR8fDz0M7OWllYExAPKCglqqup8vX1ztDMVFZRPD03v8G79/ryw629tZyurpenq5ikno2Xo5Sb",
	"zcHI8Onu9/P19/X1+fn3+vv33c/U5N3eoZKTWT9IalNayMO/0MvLf2ZzaElaq5Wi7erq4dnd083RfHV3QTg6ZV1fxMG+9fPy9fLy",
	"8vDw9PHy39zenJiaV05U5d7k3trZiICDSUNDXVhXqqen8PDw8/Lx8O/t4eDfgnx+LiothGpviXB2moSFk35+hm9whGptpI2R29DV",
	"+fj45ufkt6+tjYR96ejq5uXntrO1Y2BiNTAzV1NVrqut5+fn9PP09PPz8vHy6ujo09bUY2BgJh8hIxoaRDs6i4WCz8rH7Ojm8e7t",
	"6uTmxLu/gnZ71tTSu7a1j4WIh3uBsKWq29TX3NXX1MzP5Nzg9PLz3djbe3J45dJT0LVItJRBrItMxad55M+08+ba7OLh18nRvqu8",
	"uqW21sfT6/ntZF1ZQS01e2pzrZiqrZeqqIylooOep4qivKK50cLQ3NHb8I34y7rKcoVsW2VDm6lv5OfF6aLl75f08pb48Kbx17XJ",
	"WxJP+P/5Z2FhMh4oRCQ5RBU4XCJRrXCq25XZ2ovX2IHS2HrO1HbJ0M7Mp6ShZF9cMy0rLSUlZV5excK/9PLx9PDz8Ovv7ujt7Obr",
	"zcm71dLFioJ2PTEpWU9Jv8C67/Py6urt6Obr6ujt6+jt4Nzh9dtM689Myq1GgmUTUzkJiXVI29G5+Pbt9/L39uz19uvy9unu+e30",
	"zbnEXkhYcltu49nd+vT59ev08uby8ubx8+by9+z19Ofy2tfFkIh5Rz02NywoZVxZurax7u3q+ff2+fT19/Hz9u/y9O3w8//ubWle",
	"Mx0gYURQypzC7rzo5Z7g3ZPY5JDh4Irb4IXa3YPVvre4q5+gmouOj4CCkYKEmYqMoJGTsaCk0cLI8Ojs9/Pz6+Xh7e3j2tbQd2tl",
	"Qy4xcl1jvai52cPW0LLLwqG8u5e0xaS/1LbPkYR/QDAuIxYUJRgaRjk7pJyd8vHw+ff57+rr493f3tja2tXV9evx9evvuKewZU1d",
	"bFNly7rF+fL19un08uDw8t7w8+Hy8d/xYVBVNScgWE4/trCZ4eDMjYdwNy0gU0tCsKum6Ont7e305ebvW64uWa4uVKQpWrEwVakr",
	"VbMnV7YqeaxG5da18bHYmam/R52OZDuDYzyFYjqGZD+FYj6CVjlxPyNWOCRCkH+X6uXr9vP37Ofpmi6hu0zC8HL28XT45m3s2mXe",
	"bClwNwQ7h3SH6tvq/Pj5/v7+iomIdHV1kJCMztLQ6e/rtLOwODEyTEE/zMTH8ejq6trkyLa72NPVrqWsrKGqzcHK8OXv1MjRST5F",
	"PzI4vbK3+fP39ezyhnl/79dD9N1F9d1B9uFR69RYsY8qckcMdk4iu52D7uDd+Ozz9+nuzL+/Szc7YU1No5SRhXZzVEZFcWlpure3",
	"6+zq8fHw4uLfzsvKeGZtf21zjnyCmIeNlYKJinV+f2hxlH6HzL3C8+3v+vj59PLu08nJcWJbX09ItKyo6OnnkoqDTkA2lId/2c/I",
	"5dbR1cO+xK6qeEiHdVaNakqOZkCPq5nSysbmdV+KUC5feWF57uLh7NLap3uOop2hV05QWlJS1dLR9PLyenRyHBQSEQkJSkZCsrKv",
	"7+/t19bS6uzo2dnUlY+MTkZBMicmMSUjNicoW01MmoqPz8LH5dbe2sfQjVeQn1ilokepozmuozWpoDCjmjGgrE+21Z3d+Oj2x7rA",
	"YDxZwLqdr6mOa19ATkAon5qCu7ukZlpDVEM0raWV8/Hr9O/r6d/ks6y1s66zqqWln5yVjoh/eG1jX09CTDkvYU9Es6if7+rm8/Hu",
	"1szUVEdFU0VBwbm08O3pw7uyT0Y7ZFpO087G8ezpt6+oRz4z0HZdym5Uy29WxnFWsmNLh0EwZCUee0xJy7Cu9PDx8+7y6NznUTcr",
	"Vj0vdFxHinNjl39tjGxXXkMuY088vb2q9Pr4vrmxZ1VC6+bntKavfWx5Z1ZkY1RfY1ZgbmRsh4GFpaGmwr/F3Nnh6+juPzUxgnx6",
	"ysjIzsvLfHZ1OTEuLSMjUEdFnJiW5+Xi+Pbz6OXhbLtShdBojdl0jdh4e71zdrZubplsg7KIw57F36PU8a3r7rX3PCwsQjEpgnhx",
	"sKufsqmZpZmA0Maz/Pz1z8Gzb1ZLY0dCqZWkX0RZZlBV0sTS+vb52c7Lu62jurKmubOtj4d+RjU0QTUzp663nfKbQEk+dFR0qrOq",
	"/vn++/T8+MD63pPjmk2hcRp4aCVvdjd7im59knmGx7u/7uno9e/v8ers9O3u5t/hsZ2nk3qCnpKOnI2O0tXRTUQ/ST8uo6CSxcKn",
	"w8ClzMSj4du/3NO+eWJTXT4828XQQTU+VUxTpZ6l5ODk9/X3+/f3+vb2+fb18/LyzMnLc2xuMysvUUBAUkBCkYKK1czR8u/w9vPy",
	"6OPkrKOjXk1NOSYpRTAwZlNSmJecY15bcGplo5+e29vY6Ofi6ebf7Orj8vHw0c3NY1ZVNycqSztCVUlJxMHB5OTizsK6qZmNp5eI",
	"0MjA6OvoxcXIV0lKOiktvK24SDMqZFNJ08zJ9fXv7ebY2M6849nL8enizcG9jn14XUlFtrOznZmZl5KTr6ur1dLQ7erp9/b19PDx",
	"vbS3Z1hdYFFYraSnMys0Uk1UmZaf2tng+Pb3+fj29fTz4+Hhrqyxa2ZrRkBLUEhYQTk8kImL3tvd+fn5+/j5+fb1+vf28e/uxMDB",
	"cm5uOzY3SkRJRT5ILCIrWU9Wu7i+8/Dz9vP09vHx9/Ly5uHgo5ubQjQ1MygpaGJcnJmR1MLLwKi1r6Ohw8Gx6dzi9+b11NXPdm1n",
	"TEQ9W1ZPmJKTUUlDbmhky8fC+Pj38e/r7+zo9PHtvLWuYFhQPzUsfnZyfOZee+VefuRggexmge1lgu9mfuhhfelgfORhfedkfuJj",
	"/eH9O7M4O7M4O7M4O7M4O7M4PbU6PrM9K7skJsIbKsgaSKg1//r//73/R6RCOq03N7Y1OKwwNJsrOK0vNKEsOa4xOq00OagxN6os",
	"/az/ec5+Z8VvW9JpaOdtZvF2Y+l2Z+d3bOt3Zd52auV7cOV/WbdFWbZFYbdHXLJNarNoYrtKZrdEXbpJYLhKYbZGaLZQ1+3LxcXD",
	"4uPh4uDcpqKbgn13mZSR49/h2dXWVk9NHhcWJyAeFxANbmVx4d3i/Pv8+/j6+fb4+fb4+vj5+Pb3zcnLW1ZZGA8aGg8fcWpxz8rP",
	"9/b2+vj4+Pf2+ff3+Pf34N/el5OUSURFPjc7dW528uvv9O3x9O7x9e/z9vH09/L1+PT28ezstamqYVFOY1NMraOS7+jt6+DmzL3B",
	"raGesqanzb/G5djg6N/jvrywcWlcTkM0amdP8/Dy9vT09/T0+PT0+PX18vHw1tLRh4CCPjU2Sj9CkYiHz8bGMCYwnZye6unr8+7z",
	"8efx8+rz7uruta62UkhRHRMeHhUePDI/+ff5+/n8+/n7+/n7+/n6+/n6/Pr7/Pr64dzdhXyAJhwkHRAf49zh7u3v8PDx8vHx9PLy",
	"8e/w29TdqJuvjoCbi36ehXqZeW+NenJ65N/k+fb49/L19vP1+fX32dXXdG1yIRshFg8YIBcjLSIy+PL29e7z8ury8Ojw8erz+fX6",
	"5d/leG54HhMgGQsdJhUtMh888+/x9/X2+fb4+PX39vP09fPy7+zpwbm2ZlxaRTk1X1NMjIB3oJulurLA0MPR19DU1c/K6ePh7ePk",
	"uLCmaldOWEE4ZlBGdWNZwMDEsamxvri/19DX5+Hk7OXo7+bs9fDz29LWf292OiIsQy448u/x8O3v7+3s6ejm2tTVvrS4ppqhqp+n",
	"q6Knj4aHX1RUOy0s497h+Pb2+ff29/X29/T19vT29PPz5OHijYiJJyAiFg4UKR8pvqvS0cPa6N/d9Ovc9vLQ+fbC+Pav8emO4dBi",
	"yLIpwacb0bk1////PzFBEQgXLBQ6MBdEMRVLMRNQMxNVNBJWNRNWMxJUMxJS/v7+ycHHNyk1EgcQEwsPEQoLDwkMEAkLEAoLEAoL",
	"EAoLEQwM////Ew0UDAULDQYLDAUKDAUJCwYICwYICwYHDAYHCwUHCwYH////Szo9LykgOjgrPDosOTcoOjcpPzwwQD0wPzwvPjst",
	"Pjks////iYKLIBUkHAwkLBU6MBZCMRJIMRBKMQ9NMg5OMQ5NMhBN+AD/8AXX0QCJlQAcewAIXQAMXAAJVgAEVgACVgACVgACVgAC",
	"AAADAAACAAAHAAAABAAECQEPAAAGAAArAAAnIwAnBAAGAAAF////bFBlYUVcclJoVjdKNBwhJw4WIQsRHwoQHQoPIAwTJRIaAADU",
	"AADuaJnxZWHM/5kAAAAAAAAXAP8AAAAACgAACQkFaJlE////WExaGQojMxhCRCRbRyFkRx5rSx1yTR54UB97Uh98Uh96/wD/VAlI",
	"XgA9agBAYAAqTAABTAAATAAATAAATAAATAAATAAA////dm9yIRccGRAXHxQdHxQeHREdHA8dHBAdHRAdHREdIxgiYgmzyRrsxQDO",
	"xwB/sgBmaQAlXAASVwACUwACUwACUwACUwACAADjAAD/AAA5AABx//8AVQAAVQAuAL9x/wA5/wBIAAAAVUAc////XlpcDAcKCwYK",
	"DQcLDAcLDAcLCwcLCwcLCwcLCwcKCwcJ////nJKRQTIwOCgoRzk4Sj48Qjc0PTMuQTkyUUtFY19ac25q///+1dDSaF1jGw8UHAwb",
	"JBUkJRQrJhUsJhMvJhEuJhEwLBc2AADrAAD1AAAkAAAXIgoAAAAAAAAIAAAAAAAAKQAAAAAAAAAA////d2haUjswjX5xoZGDeGVW",
	"RjAmOiYhPiwqOygnPSssSTk6+fb3+fX2+vX3/Pj5/fv93djZSkNDMSkqvLi02dbSsa2odW9rYU9dsrSw8/Hy+vf569jqqY6nTDJJ",
	"IgohHAsZHg8cHA8ZGA8X7urs8u3y6+bo5t/i8Ovt5uDfnpCTVUFFTjk7ZVJQbVlXaVRRnZWVtLKtzMrF393aw7q8dWZsPyw1KRch",
	"JhQdOykyjYKH6+jo7+ju8evu9fLz7OrpoZeWRzU4PSotdWVjppiVoZGPhW9ufmpqe3p1vby239zh6uzo9+b119LOhYVzTEszQUQp",
	"PEAoPkEoTEs28e719fH39PD0+Pb4+vj529jeeHB8GxEfFQkfJxkxKxg7Kxg77+7u8vHx7u3t7Orp3drYrKimZV1aNy4tQzo4h4B+",
	"0MzL7+3s6+Pn6eHm7efr+vn45d/ihHl/NykyKhsmPCo4SDNFQSxARS5G9PT06OPlz8O+sKGIpZdqooZSkmkzlGInoHIyrX4+r4NA",
	"pXU98uru7ujr8+3w9vX1w7zATUFLGg4ZHxAiJRUpJhMtJBEtKBMyaVpZxr++9vP0+fj34d7ck42EUkg7Sj0uV0s7Z1tJbmFObmBL",
	"8O3t9fT0+Pb1+PX18O7uxsHDamNlMSgrKiAiRDk7dm1vurK37ebp8u7u8e7u7Ofn19LTkomKRzo9PzE0Y1hXioF8m5KNnJCK3sbs",
	"uMqyvMO08c/xzcy/XIJJQ3QwQXsuM28hNXMhRYMvRoAutKaq1dDR5dTU7d7cz76/dlxbQyckZU9Hs6+m3ubXiX5yPCUbjWxx8dfi",
	"18vJZ2FFjYt1xbjBn6ySV19ERUovS1E5Sk45V1tP6Onp5+fp2NbZwLzBpZ6mnZidhH6FYlthRj9DLCUoIRwcJB4d9/T2+fX4+fb5",
	"+vb6+vf6+vb6+vb5+vf5+/n7+vn5xb/ENCov9d/x56fv747284/19pLz8pfy8Z/y563r79jt5O7dcjyAYUZl4fuu4c3E5JzS9o/p",
	"+Y33+In79IP764Tx5onp2aXSr5SkGgE69O/v9fP02NXVm5OVh39/qKOf2NXS8e7s9/T08e7swLe2a2Fd2Mat4t7d4trS1cm8y76r",
	"zMK0zcG/2NHJ5uPf7e/tx8/JOiQcxdq93+ba37Po7a7286r6+KT49J7w7JTo5Knm6eXkvLu9RSFQrKyww73DzLrLy63MxrTFu7Ow",
	"xr2+487e+un51t/KXVNGWVc/6ePh7+Pq7+Hp69nm6NPl59Hk59Tj59nj6uXl4+jenZyYMyQoPTJDt6689/L4/vz9/Pn8+vb6+vb5",
	"/Pn8/f3939rccWluIBYexrXA1cXQ3tDZ5dvg5+Dj7Obp8uzu9fHx9vP09vX12tbWfnN1bl1j4/vJ1a7R2qDY7KDt9pL3+ZD895X8",
	"86z34tTgdl5+bGlj7u3s7u7r7+7t8e/u8fDv9PLx9fP09vT16ubooZqdYlVbgHl3wLS8opKetKWw3NTX7+nr7+js7ubr7+ju8u/y",
	"4eDgi4SINCUxQyArs+Wa3vXU6NTp87v5+bT2+7Xw97nr68Pm3OnUoameDAIk7Ofo6ufn6eTk5uDh5N3f4trd3tbc4Nrg5uHm8fDx",
	"3NjZZlVdkIWM4dve+PX3+fb59fP19PHz9PL09/b0+Pb008/Qc2tyJBki48bh37Xe7bfs87nx9bT087fx8cHw9uT07vLso4+jWilk",
	"o7qC1vLL5+bi6rXu7qPx86Dz9aP29an38LPz8dHw4OTZfVqFQitHWU5MvLm07u3q7enp6ePj5N7f5d/g7Obp7urrzcTJnI2ZmYuW",
	"c2tWoqOJ4ffOtX655aLr74P3+X35+ID3+JT57c3rdVWDjahw6+bo9fPx9/f09fbx9PLx8Ozu6+Hp39HdzbnLvai7moKXdV9sfmhz",
	"kIGGoI2awLK5zsDE283S4dDZ6tbh8eLt8+bx0cfLZVJXkp+rj52hjpmapqyv5efn9fPv8+nk9ufl7tvZyLC0lXR1mHh+g2Js1/e1",
	"4tHP7avq96n1+pz39pjz8pj276L349vpxOjGMwlXzOHozdfZ09nU4ODb7Nvk69vk49rRyN2lwNWCxt+QzN6bRDQi8u/traine3J1",
	"jYiIrqqsxb/DzMPM4Nbg8efxy8HJcWdrRj49bIpclqyL2vnL3K3f75vs95Pu95Pz8J/45q7w7uPimWuYViFY9vD0+PL2+PP2+PP2",
	"9/P2+PP29/T3+vj5+vn4zMjJXlRZIBYbXVFYwrq/8e3v+PT39/P29vP19fL09fL19/X29/X1zcjLal9kTyBB0viy4NHP5afi7pfz",
	"8pT3+JL49pL18qTw583ipI+kHAIp9O7U8fTS9O679+2j9OmX9+iU9uOY8+Gf9ue77d/KwKJ7nYBz9vLy+Pb2+ff3+vj4+vj3+vj4",
	"+vf3+vf2+vn36ubknpaUa2FdGQMUuuWW6fDb7czq9bb4+bL6+q78+az57qrs4c3Z0evCOglPQS0oc2Nb1NDQ5uPgh3xyOSgfTT0z",
	"oZqa4N3i2dbch3t9Rzc22c/N5ePizcnEj4J3VTwycV5R0cm9+vnt6+PRq5yJXEU5OyAa5+Ll6ubmpJ6aTUVBIBcTKCAeenR01dLQ",
	"wr67bWlgQDkvPzkwJSEhamlp7e7u3d7eZ2VnPDg5jYqK8e/upqOhR0BAq6Wl+PT1UjA5mYKH9fD17eHgiXJmUDUojXdtw7KvlYJ6",
	"VT4vRS8mYEtDcGlroJub2NXWure1LigmJB4ZlpOQtra0hoJ/TklFi4eG9fX35+Pk9vX38O/xv7i7Z1pbPi4veGpmy8G76uLbw7my",
	"dmVhUUA8kHZlxbi159/g49nF08Wxi2pJYToWvbSnyszEXkwkbVIyv7Sh1KLK4afY3q/VyZfAuo+umXqPVzdAa1Za7vjj0NnBRD01",
	"LiUbvJ+Sy6ya27200remmH5xa0w5jnpl4tvc9PT0opWHTjUga1VEXkcynpia6/X2enVSXkwZk4ZHpqFZq6NfsqNXrplIppZLe2k1",
	"5+Pl9vL0+fj42dDWeWpzQCs5e2l6vrHHoZKsWEBfPSFKOyFHV0tKubGt6ePbrKeeQjw5HRgUVVJSzs3O7vDxqqesR0BITkNOt7Oa",
	"UEIZuLGd0Mq8TDkXbV892dfR0M29d3FaWk4xSj8tRjkmXlVhx8LI8fH0paGjPTU0S0JD0M3L6+jmfXp3KyMiGhMTKiIjfnVXo5l7",
	"tqqNh3VTUTQSTTcbV0c4YFI5oJuO8/3/fXJhQSsXY11T1tXQ4+LedXVuKyojFxEOFhINTEpFpKKe6eno2NfVaWdj18zTvrO7oZSf",
	"cGRuV0tSSUBEbWdruLi57/Ly7O7tpKGdZFpXblhm1s/P/Pz7u7CvX0lQWUNTd2l3eGh8cmBye2t8gniFiH2Iw6u3YUhVNhopPyIy",
	"UzJEUzJFOB0sLBYiX1RZ0sjM+vr6/Pv8XUtAmYyGvrW3h3x+STw+LyIlJxodKhwcLh4cOy0qd2tn9PHy1sfUf210W0BGYkZMY0xT",
	"X05SX09TXUtPUEBBRzo4bmZf8PnwXFxLWFxFXmlOYm9OWmFFX2VIbXJYaGdNb21gblFM//v9bz0+Uj80WEY5dmhZh3lqf29iaFZL",
	"Uj82RDEtWEhEp56b7+3r9/X2goCLgX6KgH6KfnuIhICNhYKOh4OPhoGMfHV9cWlvk4uM//38gFgzhFwxpoNWr45imXBKgFA1hldF",
	"lWtbhF5TWTQsbVFL/v7/VEVDWk9LUEU/PzQoOS4fYltKsrGhv72udGlWSDcqgnVm9e71FxcREBIMDg4LCgkGLzIql5uOwMO4h4d+",
	"TUlAk4+L9/X3yMPExr62ZFtSJBkUT0c/u7uz7/HopKCXQDYxXVROvriz+PTy7urq6d7jtamsWkxNLR0gNyYoUkJFVkZJPC0wOCkr",
	"a2Jjy8bJ9PL1ZSxqcU2DeWKSbleIWDxueGGJua7AZUduTClWx7fK/fz4t6ixhlsXj2gUspEjya4v17s23sJEw6ZIekoZaUIns6eS",
	"4eDj6un1UUdFNCooOC4qaGNctbSsy87HjoyGQDo2NSwrdnBw2tfY9PT2e2ZhtaSboYqFVTs9PyYpOSMlMx8jMR0kRTI8joKL4N/l",
	"4+DiU1pMVVxOV15PWGBRVl1PVFtMUFlKVGBQV2NRS1pDVl5M/vz/KiknFxQUEA0LJSIdb25ny8vF8fLrmJeRNDEtHRgXZmNj5eTm",
	"bC2cbSmfbSeibiekbSekbCqhcDWkbDecVCV6NRFPW0Jn///9R0I/kI2L5uXi19bSW1hTHxsXJCEdHxsYLy0qdnNwzs3L9PHx5Obm",
	"goF8NS8nXVlQt7Wo5+ndyMS5bWddMSciXFNOz8nL8vDxXl5VVFJJUU5HUEtDUEhEU0pFXlVRXlZTSUM8V01Jvbm4/fz5RDoyKR0Y",
	"IxYRUEk9sq+l2trPpqCXTkI+ZFhU0cvK9e7u2dLRfG5ocWFYWUc/Tjoxc2dezs3G8ffyuLKwcl5afmhkxri25djSkoePRjVBXzte",
	"lHSU0qHR1KXUzpXOsXazWjdZQh5Aq6So9/z2d2hdiXRniXhlZVA/W0Q4YFBCTz8whXhr5OjainlzTDQ13tXbWUc7TjosXk5Ae21f",
	"j391gXFqYU5ISTcyPCwoPS8qhXx3////Ni8saWRgg317joeKi4KIi4GLk4aVoJGmoJKln5Sfs6mt//78j3+Cinl7gnNxe2xofG9o",
	"gnZtfG5mcmRbgHJttaqm9PDv8O/v5uLrr6etaV1cTT06VUc/hnpzy8S88e3n29XMj4Z8RTkvPzYwMR0uMSEvLR4qKCAiUUhN3dnZ",
	"+Pj1gn9/NjAxIBkaJh4gJBsfMQ9NMhFMMhRHLxZDHAgqDAYSj4mU////goF/GhgaEg0TEw0XMRRJLhJELBNAKhU9HAooDwcWdm56",
	"7u3w9vb1j4uNHBQZEwwRa1Z4e2iHemuDWUZcXVJavLS4+fj518/Oc2RpSTtBWU1bXlJfqqJJdk4NZR0Ah1ANxqxB8O91+e9r/fyK",
	"7+l6pHJUcxsQmHb/JB8jHhkbHRcYQDg4nJiZ393d7Onn7Ojk8u/s7uzsqKKfRz07Oi0tKRscNCYmVkpGmJGK2NTO8/Pu6ebkqqKh",
	"ZFdUZ1xXsquu19Dcf3V3RDgvT0M2nZSI5t/Y+vfy3NTOj4R8RzkwJBUQIxQStam5o5WgUUA3STgsmI+G3NbQ+Pbw+fr04N7Xk419",
	"PzYrSD825+bge3V2KSMmMSwveXN2zsbN7uXu1sfXo46kcFlxYEpjg2+Fta+6TD9DPTQxiomMt7m4nZuXj4l9zM7F+fv6oZaSUD0/",
	"dmR0wcbEMiwrGhIUQzc5kIiG1dHP8e3u8u3x8u71ysTJc2dvMiQrOSgnMiEiRzgygnZyubWx5uHf8/Tz5+ThpZ6aRDcsKhoQNycd",
	"PS05NiYvMiMrIBkUMikloJuU9vX05uLgfHJrLiUaKyIaMCchr6KnfXN0lYmMhHl6a2NggXt5xsPC+vr4vLa2X1VOdmhorqCiVz1F",
	"SC01RSwxOiQmQDEvfHJzz8zM9vf47Ojnp5yYU0Q/PS0nTEE9MSQfSTwud25pk4p5k4p2pZ2G2dXG/v7+yMC4VTw3Si8tYVhWYllZ",
	"eG90fnF6h3h+qp2k3tbZ+ff16+Xququyh256hmx8QCorak9QnYqKinJ1UjY6UDQ6s6Gf/v36wLS5ZVBUTzg9nYiO///+saCzPyJD",
	"UDBdpom7qYPJgVOoaTWWZzGYbDSdazecaDaV5fv9p5mXb0pFbz4tlGFGu31V0Ylc2oNT3XtK5HdG5nVI6ntK///9mJKLOC0mLiAc",
	"STw1aV1WiXx7fnBvTkA7MyQhNysnPDAv6+Tg2tHMgHJqQzMqbF5S2dDK9/HrvLGpZVZNMiIbMyIcSDgy5N3mfnVvTz5Ad2tq2dfT",
	"n5aTNiUhpJ2N8O7jjIJ4OiknJRcZ/Pv8lZSTSUVELisqKSUgZmNe2NfN29vTiIiAHxwWDQsKEQ0N4OPoj4qGST82ZVpQsayltq6d",
	"jYRui39kvrij9fTru7OmWERA+O/4rqGjWURCZUxHsaaXx8Cvi4FtTjsrYlFEqaCP187F18i/6+ztw8DAbWdlOS8uQjk4RD8/PDUx",
	"bWhh0dHN4OHffHZyNi8u/v/+KBQrQx5Xaj2Ofj+zfDK5fizBgirHhCnMhSnUhSfWhCvW//v3bYabOGaOMWucMXSmNX6xO4i7Po3A",
	"P5DDOoq+OYW7N4O6///+X0xYLCEkio2HnqufgY+DhZWKjqCVh5qPgpWLgJGCg5OH8ejppJmjZVVgaFtloZ2l19nd19nXo6Sdc21q",
	"c29vc25uZFpY+/b6xL+4a15QTTsvbV9Uh31yd3FiRjguRDInem5jqJuQi3hp+ff48OjvkoKUPidDRSpUiGuhnnzDc02eWS+KWi2N",
	"YDKSYjaU49n1wrTHc1E9b00rrZNDvKNQvKBJuZ1OhV8hXCgNj3RV49Wu08jJ8O7ttamlWERBQComg3Jp0cnA29DEmIR4Si4lW0A2",
	"ppaM////bV9mQCo7YEdie1+Ae1l/cEpyakNsYz9kUTBTOiA4KRIl8+/t5eLjhHptUEI4e3Zlqqubl5eFUUk3LB8ZMCMeQTIzVEhJ",
	"////bmVqV01VaF9pa2JsZ11mZ2BmZmBmZl9lZmBmZF5mZF9n/fz8dl9kOBokRSkyVTxERi81NCAlQjg4e396nqujgoyEanVr9vTs",
	"urCulYKDoZOVwLq3xL+/nJecjImVlpmgoKendX58MS4o////Lxk0NBVEUipvWSeEWyOMXR+QXh+SXx+WXR6XXR6YXCCW59zG0b+a",
	"YkAQsJds3smkTi8JbFEl8/HtkYV0GQcAMiQWZV1e59ru6eDtvq2tYj0wVjorwLqYrqmBTzoZj3xXz8+wqaKGcV5K/fr+lnuefVOE",
	"f1SDfFJ8aUJmWTpWWURUbWZrlJ2XmKaci5WP/v/+mZCSPzQyKR4cOy4sYFFPiHt6pZeYq5ugoY6Wj3yFhW568ufwcVteRzApYUxB",
	"Y09BRjQnUEk4paib2OPWm6CRUlBARj8x/v//Z09EUDEefGU+hGk+fVkoelIcg1gfi18kkmUpj2AqfEwd7+PgtqeiZFNLPiomcmRb",
	"yMO/2NbQjIN5QjAsQzIwjYKF4drc/P+zTyNAp2WUx3DCylvU1lLs3Ezz4Ub54kj54Ez22FnrzWHe5d3f+PX22c/UdmZrSzU9fGlv",
	"rZmit6OruKGqtqCnuKOov6qw5f+hg1dxwIe/y2Tm11v041j46VXx6Vf54mHw3HfijzebUBtZr0jcsEHjsz3qtDvwszzwsD7qrEPh",
	"qUrUmlS+cTaQNhlM///t9PP19PHw493ft66yn5WbopecoZSak4qMhX18gXt3hoR9iYSAwYPJxHvQxnnUxYHSv4HIwpTK2Lza8enx",
	"6+bq1srUwKrBspi2/fn67er21tnvpbjfeJnLaI/FYo3HV4fESIK/QYa+OYK6L3Gp+Pz2o56+komylI2zkIuslYqlmYyglYqamIqb",
	"nYugnYmgoY6qy5bDyX/L3o/h5YTo6YHs5njn5Hbn5o7q36TfpnqmZTtu2Py8vaaw0rLLfTaA5NHI4YDY9Xv29XT69HP763P46rnp",
	"aTttuvaQzr3FuainhXRtyc3H4uvil5eIenlor7OtvL+zmpV/pKWQioB1iW977+7l8uj0xJ/KpW6xol2wsmbCuWjMumnOumrOt2zL",
	"sm7EwXrMvnTIvHfExo7M2rvb8+ny9fDx1MDPtZC0rn+xr4C1oXGmmk2tdEZ31vC/dFGArJi3mlu1tGbQwF3kyU3uzVHzy1Tvs1XT",
	"+vzw59PkypvPqGezoFKwpU66pkrApEfBpEnCokrAnE64nVyx4tbd5djh8+jt3MzSl32FiXJ4ta+u3t/cqKKdSzk8fG9w0tjS5+bo",
	"3NvewsDEqqapo5+gwsC+3dvb6+rq1NDQmpCTioOEsKuqsznytjnzszvnlkLBhECdoHWZ/fnObjhqlF+iplrbrEnttUj34tnbx5vM",
	"v4bIxH/OzYLWzH/YyH3VyIDRx4fPv4DF0qLW6c/t+vr5UUZLTC9Ft5Wy57Pg4qPb35HTz4LCxXm1zoe+2ZHO2IzQzzjhpke6eUt6",
	"//+3bjFws1DUwDnt0zP11DLxyy/xwEjidSSN3dvY7Orm8Ovt7+Lv17nYrnysn2GgoV6loF2knl6kpm2urXi07Pf5hIGAl5aKxLms",
	"zsCy2buw1KWk1Z2f1Jue2qSmxpSXuI+LsUDsrUDnoz3XjUK1wJm+o4GSczZ4rnTFrF3XpTvYvUzqsjnX/QAD+gAA+gAB+wAD+QAD",
	"/AAD/QAB/QAA/QAA+gAA/QAA/QAA4QBp4QAA7AAA+gAA5gAA8wAA/wAA/wAx/wCH/wCK/wDw/wD/ORuihQC9ywDc7wDw/wCy9QAb",
	"tgAI7gAD7gAA7gAA7gAA7gAA/wD//wDq/wDq/wDq/wDq/wDq/wDq/wDq/wDq/wDq/wDq/wDq+QD/8wDr8gCM7AA13AAN4QAF9AAA",
	"9QAA9QAA9QAA9QAA9QAAvwAAvwAAvwAAvwAAvwAAvwAAvwAAvwAAmQBxAAAIDAz///+69Cr/6gTs3ADfxQC/xQCnyACnwgChvQCS",
	"vQCSvQCSvQCSvQCSIRIiHhEfHxIgGhAbFAsUJR0jhX+D7urs/fz8+fX3+PP09vLyRTk0TEI+f3t1kY+GZ2BZNyknTUFAsauo7Ovq",
	"9fHv9e/w8urwa0dubkxxYUJjPSE9NR40cF9vyb/I9vL19vT09fLz9vT19PHyMiQjLyEcMiQgNywkNigiUUQ7jIN22tXO4+HcjIOB",
	"c2hn3Nvfa1JYaE5VX0VOSjI2PSUoOyMgRjEqhndu497a/Pv608vIdmVgMxo+LhU4LhU4Lxo5Lxs4IBEoFQkbMigzpJyl9/T1+/f7",
	"8uvvVkVBQzAyQjAzVEVJbmBicGNld2lssqmo6ebl9fHy+PT18u3wx8O/gnV5NyYsIBMWJhodJxsbIRIULR0dZFRW0cnO8/PzZllY",
	"STpANSYsNigtNiouMSUlIxkUQDUup6Kc+vn24NvbbGBZOismLBovKhkvKRouLB0zLSEzLSAwJBkiLiYolY6Q/v39wL63YVRQurO0",
	"W09RMycnPjExQzc4NiorMSUlYVdVura07+3s8/Hu8e/uUkAvZVZCgXVhdGdVRTUqVkU+squm8e/t9PHx8u3w8enu8ejuRBpkQRpf",
	"Qh1fPyBUKQ48GgkkV0dfxrzI+PX5+/n89O/18+71wsK6XVdULB8iKyAjLyEnRTc9j4iK39rc9/P19e3y7+Ts6NrkOzEuOCsrPS8y",
	"Pi82Py4zTz5DbF1ghHR3l4eJwLW25d7f9vLzIxYhIBMeIRUeGg8YIhgefnh75uTk+/r69vT19vL09vL18ezvRDVLPzBHQDFEPjFA",
	"Pi83V0tPpJqd5eLi9fDs7eXjw7m6c1xfSSNhQyBbRyZeSChbPyNOKBI0IQ8mdmt46OPp/fz8+vj59vP0oJOSk4iHd21sSkFBJh4f",
	"JiAhW1ZYtLKy7+/v+Pb3+PX38e7xHhIgGg4aGg4bGhAbGA4XEwoRJx8jg35/5+bl+fn59/X18+/v/v38/v38/v38/v38/v38/v38",
	"/v38/v38/v38/v38/vz8/Pr6+/z79Or07tzt6NDn5Mjj48bi4sLf3r7b4L/c3LrY27nX2rvWU0tT6uXo/f38+vj4+vf4+vf6+/j6",
	"+/j7+/j7+/j7+/j7+vf5KyIpkYuO8e/u/f38+/r6+/n6+/n6/Pn6/Pn7/Pr7/Pn7+fb3wd6kz8vMxLq0pMSD4ui78avp85n49pf7",
	"9pb48ZP19qX44MvaSkdEra+mzdDGyMvBwMG4x8jA2trV7ezq9fP0+ff4+Pf15ubh9fHl+vXf+/Ta+/LQ++/I+u2++uyx+uqa+uZ7",
	"+uRr+uNw+Oak/v7+/Pv8+fj59vX28/Lz8O/w7ezt6unp5+Xm4+Hi4N7f3dvc5N3c6uTi6OTh6OXg7Orp8O/v8e/t5NzcyrzDxbe5",
	"3dTa7ers9/bg8/PV9fPT9fPR7/LG9fLS9PLT9PLd9PHh9PHf9PLm9vLv7efj/Pn2/vz4//z5/vz5/v35/v35/v35/v35/v35/vz5",
	"/vz54c7d383c4tDe5dXh59ji59ri6dzk7OLn7uXq8u7y8vPxubG3zb9At6Yozr9z8ejA/Pnn+fLp7eDe4tLR383L6NjR9Obc9+rb",
	"j+uhq9mzs+i1mO3Eq+iXoe63qPDFvOjHsOK8s+O4sOK916/lsrSn9e/t9ffz6ujmzMfIxL650MrN5ODi8u/w8/Lz8/Ly8vDwzbTI",
	"zrXK1b/S28jX3MnY2cbV2MXU4c/e693o8+nw9vH0+Pf38e3q8+/v6eDlzbzJs5uvu6O51MDT6Nvn8urx9O/z9O/y8e3vSj1DvLa3",
	"+vn4+PX39O/y9fD09vH29vH19vD09vD19e/09O3ypYybsZqozrzI7eLo9e7w9/Lz+fX1+vf4+/n5+/r5+/v6+Pb27NLax+XgxOTn",
	"x+nryOnrwuvrtujsoujvounwm+fvl+jvmOju7+3n8/Lv9fT07e3t2NbXvLm6sK2vtbKztrW2ube3t7W2rKep2azX1qXV2abY3a3c",
	"47nh7M3p9ODx+u72/PX3+/f2/Pn3+/j29PTz8e/w8e3w8Ozx7+vw7uvw7uvw7uvw7uvx7uzx7+3x9PX27t7u7Njt69Xt6tPs69Xt",
	"7Njv7dvv8ODw8+bz9Ony9e3z9/T18/Hw+vj3/Pn5/Pr6/Pr6/Pr6+/n5+/j5+/n5/Pr66+jnin5/fnl06ufk+Pj37+vt6+fp6+fo",
	"6+jo6+jo7Onp7Onq6+jp5uLl5dfe7+Xp8OPu7uDu7ODq29TYopicj36G2dHS7+7r7Ozq6OHk/Pv5/fv6/Pr5+/n4+fb3+PT29vD1",
	"9O308urz8enz8enz8evy8ens2cjVsZiutJyy2cjY8+rw9O/w7+zq7+vp8u7s8/Dt9PLwn6SypKi4oqe0rrC4zc/R5+no7+7r6+jl",
	"5NnW3c7K1sjEz8G/9fHz9fPy9PHx8+/w8/Dx9vPz9vTy8/Hx6+Tp1MXRw7HBxrHE3LbZ2KnV053R1pzU1p3V2KHX16HV0aDQ167V",
	"5cjj7+Lv9vX18Ozv8+/x8Ozv7eft6N7p3Mve0LvT2sTd3Mre6tzq8Ojv7+rs0tPYxsnKzczQ1NbX1tXX1NPU0c3PzMbGzcXH08vN",
	"29XY+ff3oZqe9/T0/fr7+/j5+/j5+/j6/Pj6/Pj6/Pn7/Pn7/Pn7+/j67Orty8TLva+6z8HM39Pf0cLPvKy2ua6x3tbY6+Xj08TA",
	"sZqV8fLr+vv6/vz6/vv2/fXm/fLa/e/R/u3K/e3I/e3L/e7P/PDW2dnZ29ra4d/h7Ovr5+Tl3dja29fY5OPk4+PiraankYaH0cvJ",
	"yqvR4Mjm8OPz+PT4+fn3+fr39/f29vX38+z16Njq3MPe17fZ8OTw5eLkt7CzoqKdrqqpxsnAxMC/vLW2v7C4z8DH1MXN1M3K9/Tx",
	"8evu183Uz8TN2c/W7+rt+vj4/fz7/vz6/vz7/vz6/fv5yaGry6Cqy56o0qiv1K2zyqOpxqGo07W759TX8efp8/Ly7vLxpaen3dnd",
	"7err5dvi1cLP0rvN2LjS27PX3qzZ2ajU2qjV3K/Y+/f5/Pn6/Pn6/Pr6/Pr7/Pr7/fv7/Pv7/Pr7+vj58/DyzsXMZlNWcWBl3NPU",
	"+/r49/L19u/09u/09e7z9e3z9e/z8+3z8erw+/f59ez05srk2KvY1J7W1ZnY05LV0pDW05LW0pXV1p/Y2ava9PPC9PCp8+yb9++V",
	"9+yP9+yN9eqJ9emK9OqS8uia7ua47dvj9+309+z29+z2+e74+vD4+/L5/PT6/PX7/Pb7/Pf7/Pf7/fv7+vX4+/n6/Pr6+vf5+vP4",
	"8uLx5Mjk2LDZ06LV057W06DW1KnW59nk1cfT4NTe9Ozy+/j6/fv8/fv8/fz8/v38/v38/fz8+/r6",
})
local CEN = table.concat({
	"Xk1NXk9Ktayn8e/rz8rEe3BpTT84Y1NQgnV1i31+fGxscGBjfXd3VUdHZFdYmpqT18rQ6uLk7uPm69/j6dzg697h6t/i49najHt9",
	"uKyq0MLF1cbI1cHH1sLFyLa2opGMinlzopSMysC51cnFRSo4NhooLhMhLRMgLxYiMBgjLhYgKRIZNBgeWkFDnIiN8N3k4tibzrpo",
	"x69OzLZL2sdV6txr38xd1sdc1cxqzMl0t69kq6dzl5KIVUtCS0E1m4uG4dff1s3Sk49+ZldSZlBUal9XZ1hTbFha1tHT7ObqxsLC",
	"endyQDk2MiwpOTIwPzg3Qzo6Rz4/UUhKYFpbuKin0MHA5dfX18fHpJORcWJfeW1mtq2o3tXU6d/f49zYysK/3NLKr6WcdWhhXU1K",
	"eGlorqKj1sfQ3s7b2sjY2cjX1sbSxLK/n5CLinl0i3h0oY+NqJmXi3p3WUhGZlZVsKGk5trf5NvgxLq/c25uYFZWlYqNzMjH497b",
	"4NvU5NrY5NvcxLm7hXV6W0pOb2BonL6SXcBSWcBOVcVPW8hUWclPWchOU8hKVMtJVcpJXcNRst6wwrzD4Nvg7Ofp6eTl5+Lh6uXk",
	"6OPhyMG/ioF+WExISz87XlFOwaHpZUSIPh5CPBs6VC4pMhQhLRAhJyYkNQ8iOhAkKhIgNh8ny8PH39zc5+Li493c08vKnpWSXlVP",
	"RTs0VEtDY1xUaF9XbGJcsKmn0dHJ3tHY4cfc6Mfj7Mfm7sjo783p7tbp3dbXnZGXVURPkYKAua2s29PSsaahZVVNUUA3f3Nrtq+p",
	"ubStk4qBbWBZaVtVdWZlaVpYZldVaVpXdmdkhXd1g3V0aFhaXU5QeGtstq+v6ubndmlwVkZMTDo/VkdHdWpmpp6Y1tDI5uPcv7m0",
	"fG9sUD4/V0hS9PHynZKWYE1SXUpPeWhtiXl9inl+hnV7gW92eGdxcmBqblxn1bPVupLBuJC/u5HBs4K8tX++vYTFvoLJuX7ErHO4",
	"oG2trIm00wqU2wGA5AB15wBn5ABV5gA+4QA66AA+4wBazQBLzwJ98SR1WUdUSDZEQjE+Pi45NicxPjA2ZVpdpZ6f2tXW7Ofo4Nvc",
	"zcXHz8nH3tfX5Nzd5d7f5t/f597g5tzf5tzg6d7i6d/i6N/i5dzh",
})
local STARTS = { 0, 17, 46, 77, 89, 106, 125, 140, 159, 184, 206, 222, 227, 244, 263, 281, 314, 333, 361, 381, 411, 435, 442, 462, 512 }
local lib = table.create(N * D, 0)
local cen = table.create(NC * D, 0)
do
	local b = EncodingService:Base64Decode(buffer.fromstring(LIB))
	for i = 0, N * D - 1 do
		lib[i + 1] = buffer.readu8(b, i) / 255
	end
	local c = EncodingService:Base64Decode(buffer.fromstring(CEN))
	for i = 0, NC * D - 1 do
		cen[i + 1] = buffer.readu8(c, i) / 255
	end
end
-- The pool: Shapes.Slots shapes, the generic ones to start with. A cell takes the nearest shape when it is close enough
-- (Shapes.ShareRms, colour units); otherwise a shape no cell uses any more is replaced by the cell's own, so the pool
-- follows what is on screen (a video's own colours: the generic shapes alone drew saturated rainbow-like strips badly).
-- At most Shapes.MaxNewPerFrame shapes are replaced per frame (each is a new gradient for Roblox).
Shapes.Slots = 640
Shapes.ShareRms = 6
Shapes.MaxNewPerFrame = 80
local S = Shapes.Slots
local prof = table.create(S * D, 0) -- the pool's shapes
table.move(lib, 1, N * D, 1, prof)
local refs = table.create(S, 0)
local seqs = {}
local groupOf, posOf = table.create(S, 0), table.create(S, 0)
local groups = {} -- [group] = { slot, ... }
local free, freeHead, freeTail = {}, 1, 0 -- slots no cell uses (queue: the longest unused first)
local inFree = table.create(S, false)
local function pushFree(i)
	if not inFree[i] then
		inFree[i] = true
		freeTail += 1
		free[freeTail] = i
	end
end
local function dist(arr, base, p, best)
	local d = 0
	for k = 1, D do
		local e = arr[base + k] - p[k]
		d += e * e
		if d >= best then
			return d
		end
	end
	return d
end
local function nearestGroups(p)
	local b1, b2, d1, d2 = 0, 0, math.huge, math.huge
	for c = 0, NC - 1 do
		local d = dist(cen, c * D, p, d2)
		if d < d1 then
			b2, d2 = b1, d1
			b1, d1 = c, d
		elseif d < d2 then
			b2, d2 = c, d
		end
	end
	return b1, b2
end
local function addToGroup(i, c)
	local g = groups[c]
	table.insert(g, i)
	groupOf[i], posOf[i] = c, #g
end
local function removeFromGroup(i)
	local g = groups[groupOf[i]]
	local p, last = posOf[i], #g
	local j = g[last]
	g[p], posOf[j] = j, p
	g[last] = nil
end
for c = 0, NC - 1 do
	groups[c] = {}
end
for i = 1, S do
	if i <= N then
		local c = 0
		for g = 0, NC - 1 do
			if i - 1 >= STARTS[g + 1] and i - 1 < STARTS[g + 2] then
				c = g
			end
		end
		addToGroup(i, c)
	end
end
for i = N + 1, S do -- the empty slots first, then the generic ones as they are given up
	groupOf[i] = -1
	pushFree(i)
end
for i = 1, N do
	pushFree(i)
end

local frameNo, newFrame, newCount = 0, -1, 0
pcall(function()
	game:GetService("RunService").Heartbeat:Connect(function()
		frameNo += 1
	end)
end)

-- nearest shape in the pool: the 2 nearest groups, then every shape in them -> slot, squared distance, nearest group
local function nearest(p)
	local b1, b2 = nearestGroups(p)
	local best, bd = 1, math.huge
	for pass = 1, 2 do
		local g = groups[pass == 1 and b1 or b2]
		for q = 1, #g do
			local i = g[q]
			local d = dist(prof, (i - 1) * D, p, bd)
			if d < bd then
				best, bd = i, d
			end
		end
	end
	return best, bd, b1
end

-- a shape for profile p (36 numbers, 0..1) whose brightest channel is tmax (0..255): slot index, and the squared
-- colour error per value. The slot is in use until Shapes.drop(slot). i, d: Shapes.match(p) when already known.
function Shapes.take(p, tmax, i, d)
	local g
	if not i then
		i, d, g = nearest(p)
	end
	local scale = tmax * tmax / D
	if d * scale > Shapes.ShareRms * Shapes.ShareRms then
		if newFrame ~= frameNo then
			newFrame, newCount = frameNo, 0
		end
		-- a free slot gets this profile (the oldest unused one)
		while freeHead <= freeTail and newCount < Shapes.MaxNewPerFrame do
			local j = free[freeHead]
			free[freeHead] = nil
			freeHead += 1
			inFree[j] = false
			if refs[j] == 0 then
				if groupOf[j] >= 0 then
					removeFromGroup(j)
				end
				local base = (j - 1) * D
				for k = 1, D do
					prof[base + k] = p[k]
				end
				seqs[j] = nil
				addToGroup(j, g or (nearestGroups(p)))
				newCount += 1
				i, d = j, 0
				break
			end
		end
	end
	refs[i] += 1
	return i, d * scale
end

function Shapes.drop(i)
	if i and i > 0 then
		local r = refs[i] - 1
		refs[i] = r
		if r <= 0 then
			refs[i] = 0
			pushFree(i)
		end
	end
end

-- the nearest shape in the pool (not taken): slot, squared distance (sum over the 36 values)
function Shapes.match(p)
	local i, d = nearest(p)
	return i, d
end

local Keypoint, new3 = ColorSequenceKeypoint.new, Color3.new
function Shapes.sequence(i)
	local s = seqs[i]
	if not s then
		local kp = table.create(P)
		local base = (i - 1) * D
		for k = 0, P - 1 do
			kp[k + 1] = Keypoint(k / (P - 1), new3(math.clamp(prof[base + k * 3 + 1], 0, 1), math.clamp(prof[base + k * 3 + 2], 0, 1),
				math.clamp(prof[base + k * 3 + 3], 0, 1)))
		end
		s = ColorSequence.new(kp)
		seqs[i] = s
	end
	return s
end

-- shapes in use (each is one gradient for Roblox)
function Shapes.inUse()
	local n = 0
	for i = 1, S do
		if refs[i] > 0 then
			n += 1
		end
	end
	return n
end
return Shapes
