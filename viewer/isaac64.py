# -*- coding: utf-8 -*-
"""ISAAC64 前缀解密（移植自 wx_channels_download decrypt.go，已用本地 videoCache 分片验证）。

规则（实证）：
  - seed = decodeKey 十进制串转 uint64；
  - 密文前 enclen 字节（通常 131072）用 ISAAC64 大端 8 字节密钥流逐字节异或，其后为明文；
  - 密钥流顺序：Isaac.random() 每 8 字节一组，struct.pack(">Q", rn) 大端。
"""
import struct

MASK = 0xFFFFFFFFFFFFFFFF
GOLDEN = 0x9E3779B97F4A7C13


def _mix(a, b, c, d, e, f, g, h):
    a = (a - e) & MASK
    f ^= h >> 9
    h = (h + a) & MASK
    b = (b - f) & MASK
    g ^= a << 9
    a = (a + b) & MASK
    c = (c - g) & MASK
    h ^= b >> 23
    b = (b + c) & MASK
    d = (d - h) & MASK
    a ^= c << 15
    c = (c + d) & MASK
    e = (e - a) & MASK
    b ^= d >> 14
    d = (d + e) & MASK
    f = (f - b) & MASK
    c ^= e << 20
    e = (e + f) & MASK
    g = (g - c) & MASK
    d ^= f >> 17
    f = (f + g) & MASK
    h = (h - d) & MASK
    e ^= g << 14
    g = (g + h) & MASK
    return [x & MASK for x in (a, b, c, d, e, f, g, h)]


class Isaac:
    def __init__(self, enc_key):
        self.rand_cnt = 255
        self.seed = [0] * 256
        self.mm = [0] * 256
        self.aa = self.bb = self.cc = 0
        self.seed[0] = int(enc_key) & MASK
        a = b = c = d = e = f = g = h = GOLDEN
        for _ in range(4):
            a, b, c, d, e, f, g, h = _mix(a, b, c, d, e, f, g, h)
        for i in range(0, 256, 8):
            a = (a + self.seed[i]) & MASK
            b = (b + self.seed[i + 1]) & MASK
            c = (c + self.seed[i + 2]) & MASK
            d = (d + self.seed[i + 3]) & MASK
            e = (e + self.seed[i + 4]) & MASK
            f = (f + self.seed[i + 5]) & MASK
            g = (g + self.seed[i + 6]) & MASK
            h = (h + self.seed[i + 7]) & MASK
            a, b, c, d, e, f, g, h = _mix(a, b, c, d, e, f, g, h)
            self.mm[i:i + 8] = [a, b, c, d, e, f, g, h]
        for i in range(0, 256, 8):
            a = (a + self.mm[i]) & MASK
            b = (b + self.mm[i + 1]) & MASK
            c = (c + self.mm[i + 2]) & MASK
            d = (d + self.mm[i + 3]) & MASK
            e = (e + self.mm[i + 4]) & MASK
            f = (f + self.mm[i + 5]) & MASK
            g = (g + self.mm[i + 6]) & MASK
            h = (h + self.mm[i + 7]) & MASK
            a, b, c, d, e, f, g, h = _mix(a, b, c, d, e, f, g, h)
            self.mm[i:i + 8] = [a, b, c, d, e, f, g, h]
        self._isaac64()

    def _isaac64(self):
        self.cc = (self.cc + 1) & MASK
        self.bb = (self.bb + self.cc) & MASK
        for i in range(256):
            m = i % 4
            if m == 0:
                self.aa = ~(self.aa ^ (self.aa << 21)) & MASK
            elif m == 1:
                self.aa ^= self.aa >> 5
            elif m == 2:
                self.aa ^= self.aa << 12
            else:
                self.aa ^= self.aa >> 33
            self.aa &= MASK
            self.aa = (self.aa + self.mm[(i + 128) % 256]) & MASK
            x = self.mm[i]
            y = (self.mm[(x >> 3) % 256] + self.aa + self.bb) & MASK
            self.mm[i] = y
            self.bb = (self.mm[(y >> 11) % 256] + x) & MASK
            self.seed[i] = self.bb

    def random(self):
        result = self.seed[self.rand_cnt]
        if self.rand_cnt == 0:
            self._isaac64()
            self.rand_cnt = 255
        else:
            self.rand_cnt -= 1
        return result

    def decrypt(self, data, enc_len):
        data = bytearray(data)
        for i in range(0, enc_len, 8):
            rn = self.random()
            temp = struct.pack(">Q", rn)
            for j in range(8):
                idx = i + j
                if idx >= enc_len:
                    return bytes(data)
                data[idx] ^= temp[j]
        return bytes(data)


def decrypt_prefix(raw: bytes, seed, enc_len: int) -> bytes:
    """解密 raw 的前 enc_len 字节，返回完整明文（前缀解密 + 原尾部）。"""
    inst = Isaac(seed)
    enc_len = min(enc_len, len(raw))
    return inst.decrypt(raw[:enc_len], enc_len) + raw[enc_len:]
