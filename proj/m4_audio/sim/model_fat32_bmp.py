#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
model_fat32_bmp.py -- M2 的离线验证模型（本机没有 iverilog/verilator/Questa）

本文件做三件事，全部是纯 Python（无第三方依赖）：

  1) Fat32Builder : 在内存里"造一张 TF 卡"——MBR 分区表 + FAT32 BPB + 两份 FAT +
                    根目录 + 若干 BMP 文件。可以故意造出：碎片簇链、LFN 长文件名项、
                    0xE5 删除项、子目录项、非 BMP 文件、尺寸不合法的 BMP、
                    带 1078 字节调色板前缀的 BMP、以及"链提前结束"的坏文件。

  2) RtlModel     : 把 rtl/m2_fat_bmp.v 的状态机逐条照抄成 Python：
                    POR → 10 ms 延时 → SD 初始化 → MBR(或 superfloppy) → BPB →
                    根目录簇链扫描（32 字节/项，跳过 0xE5 / 0x0F / 0x10 / 0x08）→
                    串行 min/max 扫描选图 → 读文件首扇区校验 BMP 头 →
                    逐扇区流式读（按 skip 跳过调色板）→ 每 3 字节装一个 {0,R,G,B} →
                    按行 LOAD 写页（自底向上 → 行地址递减）。
                    同时模拟 Sdram_Control_4Port 的写侧：128 字一个突发。

  3) 检查项       : 图像方向/颜色/页地址映射、每行 5 个突发且 128 字对齐、
                    行末写 FIFO 必空、DRAIN 等待的上界、失败回退（黑填充/图案）、
                    扇区数与加载时间估算。

运行
    python model_fat32_bmp.py                # 跑全部场景，打印 PASS/FAIL 汇总
    python model_fat32_bmp.py -v             # 额外打印扇区序列/统计
    python model_fat32_bmp.py --dump-page    # 把解码后的页写成 PNG（需要 Pillow）

退出码 0 = 全部通过，1 = 有失败项。
"""

import argparse
import struct
import sys

# ==========================================================================
#  常量：与 RTL 完全一致
# ==========================================================================
W, H = 640, 480
ROW_BYTES = W * 3                 # 1920
PIX_BYTES = ROW_BYTES * H         # 921600
HDR_BYTES = 54
SEC = 512
PAGE_A_BASE = 0x000000            # 字地址
PAGE_B_BASE = 0x04B000            # 307200 字
PAGE_END = 0x096000
DRAIN_CLOCKS = 4096               # m2_page_wr.v 的 DRAIN 参数
EOC = 0x0FFFFFF8
MAXF = 16                         # 最多索引多少个 *.BMP

RESULTS = []


def check(name, cond, detail=''):
    RESULTS.append((bool(cond), name, detail))
    print('  [%s] %-52s %s' % ('PASS' if cond else 'FAIL', name, detail))
    return cond


# ==========================================================================
#  1) 造卡
# ==========================================================================
class Fat32Builder:
    def __init__(self, part_lba=2048, rsvd=32, nfats=2, spc=8, nclusters=640):
        self.part_lba = part_lba
        self.rsvd = rsvd
        self.nfats = nfats
        self.spc = spc
        self.nclusters = nclusters
        self.fatsz = (nclusters * 4 + SEC - 1) // SEC
        self.data_lba = part_lba + rsvd + nfats * self.fatsz
        self.total_sectors = self.data_lba + nclusters * spc
        self.fat = [0] * (nclusters + 2)
        self.fat[0] = 0x0FFFFFF8
        self.fat[1] = 0x0FFFFFFF
        self.data = {}                    # clus -> bytearray(spc*512)
        self.dir = bytearray()            # 根目录项流
        self.next_free = 3                # 簇 2 是根目录
        self.lba_log = []

    # ---- 簇分配 -----------------------------------------------------------
    def alloc(self, n, chain=None):
        if chain is not None:
            cl = list(chain)
            assert len(cl) == n, (len(cl), n)
            for c in cl:
                self.data[c] = bytearray(self.spc * SEC)
            return cl
        cl = list(range(self.next_free, self.next_free + n))
        assert cl[-1] <= self.nclusters + 1, 'out of clusters'
        self.next_free += n
        for c in cl:
            self.data[c] = bytearray(self.spc * SEC)
        return cl

    def _chain(self, cl):
        for a, b in zip(cl, cl[1:]):
            self.fat[a] = b
        self.fat[cl[-1]] = 0x0FFFFFFF

    # ---- 目录项 -----------------------------------------------------------
    @staticmethod
    def name83(name):
        """'IMG0001.BMP' -> 11 字节 8.3 名"""
        if '.' in name:
            base, ext = name.rsplit('.', 1)
        else:
            base, ext = name, ''
        base = base.upper()[:8].ljust(8)
        ext = ext.upper()[:3].ljust(3)
        return (base + ext).encode('ascii')

    def add_entry(self, name11, attr, clus, size):
        e = bytearray(32)
        e[0:11] = name11
        e[11] = attr
        e[12] = 0                    # NTRes
        e[13] = 0                    # CrtTimeTenth
        struct.pack_into('<H', e, 20, (clus >> 16) & 0xFFFF)   # clus hi
        struct.pack_into('<H', e, 26, clus & 0xFFFF)           # clus lo
        struct.pack_into('<I', e, 28, size)
        self.dir += e

    def add_lfn(self, longname):
        """一个（假的）LFN 项：属性 0x0F，RTL 只检查 attr == 0x0F 就跳过"""
        e = bytearray(32)
        e[0] = 0x41                                  # 'A' 序号
        nm = longname.encode('utf-16-le')[:26]
        e[1:1 + len(nm)] = nm
        e[11] = 0x0F
        e[13] = 0x00
        e[26] = 0
        e[27] = 0
        self.dir += e

    def add_file(self, name, payload, chain=None, longname=None):
        n = max(1, (len(payload) + self.spc * SEC - 1) // (self.spc * SEC))
        cl = self.alloc(n, chain)
        for i, c in enumerate(cl):
            chunk = payload[i * self.spc * SEC:(i + 1) * self.spc * SEC]
            self.data[c][0:len(chunk)] = chunk
        self._chain(cl)
        if longname:
            self.add_lfn(longname)
        self.add_entry(self.name83(name), 0x20, cl[0], len(payload))
        return cl

    def add_dir(self, name, chain=None):
        cl = self.alloc(1, chain)
        self._chain(cl)
        self.add_entry(self.name83(name), 0x10, cl[0], 0)
        return cl

    def add_deleted(self, name):
        e = bytearray(32)
        e[0:11] = self.name83(name)
        e[0] = 0xE5
        e[11] = 0x20
        self.dir += e

    def add_raw_entry(self, raw32):
        self.dir += bytes(raw32)

    # ---- 组装 -------------------------------------------------------------
    def build(self, fs_label=b'FAT32   '):
        img = bytearray(self.total_sectors * SEC)

        # --- MBR ---
        mbr = bytearray(SEC)
        p = 446
        mbr[p + 0] = 0x00                      # not bootable
        mbr[p + 4] = 0x0C                      # FAT32 LBA
        struct.pack_into('<I', mbr, p + 8, self.part_lba)
        struct.pack_into('<I', mbr, p + 12, self.nclusters * self.spc)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        img[0:SEC] = mbr

        # --- BPB (在 part_lba) ---
        bpb = bytearray(SEC)
        bpb[0:3] = b'\xEB\x58\x90'             # jmp + nop
        bpb[3:11] = b'MSWIN4.1'
        struct.pack_into('<H', bpb, 11, SEC)               # BytsPerSec
        bpb[13] = self.spc                                  # SecPerClus
        struct.pack_into('<H', bpb, 14, self.rsvd)          # RsvdSecCnt
        bpb[16] = self.nfats                                # NumFATs
        struct.pack_into('<H', bpb, 17, 0)                  # RootEntCnt = 0 (FAT32)
        struct.pack_into('<H', bpb, 19, 0)                  # TotSec16
        bpb[21] = 0xF8                                      # Media
        struct.pack_into('<H', bpb, 22, 0)                  # FATSz16 = 0
        struct.pack_into('<I', bpb, 32, 0)                  # TotSec32
        struct.pack_into('<I', bpb, 36, self.fatsz)         # FATSz32
        struct.pack_into('<H', bpb, 40, 0)
        struct.pack_into('<H', bpb, 42, 0)
        struct.pack_into('<I', bpb, 44, 2)                  # RootClus = 2
        struct.pack_into('<H', bpb, 48, 1)                  # FSInfo
        struct.pack_into('<H', bpb, 50, 6)                  # BkBootSec
        bpb[64] = 0x80
        bpb[66] = 0x29
        struct.pack_into('<I', bpb, 67, 0x12345678)         # 卷序列号
        bpb[71:82] = b'M2   FAT32 '
        bpb[82:90] = fs_label
        bpb[510] = 0x55
        bpb[511] = 0xAA
        img[self.part_lba * SEC:(self.part_lba + 1) * SEC] = bpb

        # --- FAT x nfats ---
        fat_bytes = bytearray(self.fatsz * SEC)
        for i, v in enumerate(self.fat):
            if i * 4 + 4 <= len(fat_bytes):
                struct.pack_into('<I', fat_bytes, i * 4, v & 0x0FFFFFFF)
        for k in range(self.nfats):
            off = (self.part_lba + self.rsvd + k * self.fatsz) * SEC
            img[off:off + len(fat_bytes)] = fat_bytes

        # --- 根目录：簇 2 ---
        self.fat[2] = 0x0FFFFFFF
        if 2 not in self.data:
            self.data[2] = bytearray(self.spc * SEC)
        d = self.dir
        assert len(d) <= self.spc * SEC, 'root directory is bigger than one cluster'
        self.data[2][0:len(d)] = d

        # --- 数据区 ---
        for c, buf in self.data.items():
            off = (self.data_lba + (c - 2) * self.spc) * SEC
            img[off:off + len(buf)] = buf
        return bytes(img)


class Disk:
    def __init__(self, img):
        self.img = img
        self.log = []

    def read_sector(self, lba):
        self.log.append(lba)
        off = lba * SEC
        if off + SEC > len(self.img):
            return bytes(SEC)                 # 越界读 0：模拟失败
        return self.img[off:off + SEC]


# ==========================================================================
#  BMP 生成（和 tools/make_bmp.py 的字节格式一致）
# ==========================================================================
def make_bmp(rgb_top_down, width=W, height=H, bpp=24, bf_off=HDR_BYTES,
             palette_bytes=0, bi_size=40, comp=0, bad_bm=False):
    """rgb_top_down: bytes, width*height*3 的 RGB 流（自上而下）"""
    pix = bytearray()
    for y in range(height - 1, -1, -1):        # 自底向上
        line = bytearray(rgb_top_down[y * width * 3:(y + 1) * width * 3])
        line[0::3], line[1::3], line[2::3] = line[2::3], line[1::3], line[0::3]
        pix += line
    out = bytearray()
    out += (b'XX' if bad_bm else b'BM')
    off = HDR_BYTES + palette_bytes
    struct.pack_into
    out += struct.pack('<I', off + len(pix))
    out += struct.pack('<HH', 0, 0)
    out += struct.pack('<I', off)
    out += struct.pack('<I', bi_size)
    out += struct.pack('<i', width)
    out += struct.pack('<i', height)
    out += struct.pack('<H', 1)
    out += struct.pack('<H', bpp)
    out += struct.pack('<I', comp)
    out += struct.pack('<I', len(pix))
    out += struct.pack('<i', 2835)
    out += struct.pack('<i', 2835)
    out += struct.pack('<I', 0)
    out += struct.pack('<I', 0)
    assert len(out) == HDR_BYTES
    out += bytes(palette_bytes)                # 假的调色板/前缀
    out += pix
    return bytes(out)


def test_image(tag):
    """确定性的测试图：左上红、右上绿、左下蓝、右下白 + 每 64 px 的棋盘 + 标记"""
    buf = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            i = (y * W + x) * 3
            r = x * 255 // (W - 1)
            g = y * 255 // (H - 1)
            b = 255 - ((x * y) // 700) % 256
            if ((x >> 6) + (y >> 6)) & 1:
                b = (b + 96) & 0xFF
            # 用一个可识别的角标保证方向能被区分
            if x < 32 and y < 32:
                r, g, b = 255, 0, 0           # 左上：纯红
            if x >= W - 32 and y < 32:
                r, g, b = 0, 255, 0           # 右上：纯绿
            if x < 32 and y >= H - 32:
                r, g, b = 0, 0, 255           # 左下：纯蓝
            if x >= W - 32 and y >= H - 32:
                r, g, b = 255, 255, 255       # 右下：纯白
            buf[i] = r
            buf[i + 1] = g
            buf[i + 2] = b
    return bytes(buf)


# ==========================================================================
#  2) 写侧模型：m2_page_wr.v + Sdram_Control_4Port 的 128 字突发
# ==========================================================================
class PageWriter:
    def __init__(self, page_base):
        self.base = page_base
        self.reset_page()

    def reset_page(self):
        self.page = {}
        self.writes = 0
        self.fifo = 0                 # FIFO 里的字数（只关心 128 的倍数部分）
        self.bursts = 0
        self.loads = []               # 每个 WR1_LOAD 的地址
        self.row = 0
        self.x = 0
        self.bottom_up = True
        self.row_end_fifo = []        # 每行写完时 FIFO 的残留字数
        self.row_bursts = []
        self.dups = 0
        self._rb = 0

    def start(self, bottom_up):
        self.reset_page()
        self.bottom_up = bottom_up
        self.row = (H - 1) if bottom_up else 0

    def push(self, word):
        if self.x == 0:
            self.loads.append(self.base + self.row * W)
        addr = self.base + self.row * W + self.x
        if addr in self.page:
            self.dups += 1
        self.page[addr] = word
        self.writes += 1
        self.fifo += 1
        while self.fifo >= 128:                  # 控制器：够 128 字就发一个突发
            self.fifo -= 128
            self.bursts += 1
            self._rb += 1
        self.x += 1
        if self.x == W:
            self.row_end_fifo.append(self.fifo)
            self.row_bursts.append(self._rb)
            self._rb = 0
            self.x = 0
            self.row += -1 if self.bottom_up else 1


# ==========================================================================
#  3) FAT32/BMP 状态机模型（照抄 rtl/m2_fat_bmp.v）
# ==========================================================================
class RtlModel:
    def __init__(self, disk, page_base=PAGE_B_BASE, verbose=False):
        self.d = disk
        self.page_base = page_base
        self.v = verbose
        self.w = PageWriter(page_base)
        self.sectors = 0
        self.pixels = 0
        self.files = []          # [(key, clus, size, name)]
        self.count = 0
        self.cur_key = 0xFFFF
        self.cur_idx = 0
        self.err = 0
        self.pattern = False
        self.events = []

    # ---------------- 基本操作 ----------------
    def rd(self, lba):
        self.sectors += 1
        return self.d.read_sector(lba)

    def log(self, s):
        self.events.append(s)
        if self.v:
            print('    . ' + s)

    # ---------------- 挂载 ----------------
    def mount(self):
        mbr = self.rd(0)
        if mbr[82:87] == b'FAT32':
            self.part_lba = 0
            bpb = mbr
            self.log('super floppy: BPB at LBA 0')
        else:
            self.part_lba = None
            for k in range(4):
                p = 446 + 16 * k
                ptype = mbr[p + 4]
                lba = struct.unpack_from('<I', mbr, p + 8)[0]
                self.log('MBR entry %d: type 0x%02X lba %d' % (k, ptype, lba))
                if ptype in (0x01, 0x04, 0x06, 0x0B, 0x0C, 0x0E) and lba:
                    self.part_lba = lba
                    break
            if self.part_lba is None:
                self.err = 2
                self.log('no usable partition')
                return False
            bpb = self.rd(self.part_lba)

        byts = struct.unpack_from('<H', bpb, 11)[0]
        self.spc = bpb[13]
        self.rsvd = struct.unpack_from('<H', bpb, 14)[0]
        self.nfat = bpb[16]
        self.fatsz16 = struct.unpack_from('<H', bpb, 32)[0]
        self.fatsz = struct.unpack_from('<I', bpb, 36)[0]
        self.root_clus = struct.unpack_from('<I', bpb, 44)[0]

        if not (byts == SEC and self.fatsz16 == 0 and self.fatsz and
                self.root_clus >= 2 and 1 <= self.nfat <= 2 and self.rsvd and
                self.spc and (self.spc & (self.spc - 1)) == 0):
            self.err = 2
            self.log('BPB rejected: byts=%d fatsz16=%d fatsz=%d root=%d nfat=%d spc=%d'
                     % (byts, self.fatsz16, self.fatsz, self.root_clus, self.nfat, self.spc))
            return False

        self.log2spc = self.spc.bit_length() - 1
        self.fat_lba = self.part_lba + self.rsvd
        self.data_lba = (self.part_lba + self.rsvd +
                         (self.fatsz * 2 if self.nfat == 2 else self.fatsz))
        self.log('BPB ok: spc=%d rsvd=%d nfat=%d fatsz=%d root=%d fat_lba=%d data_lba=%d'
                 % (self.spc, self.rsvd, self.nfat, self.fatsz, self.root_clus,
                    self.fat_lba, self.data_lba))
        return True

    def clus_lba(self, clus, sec=0):
        return self.data_lba + ((clus - 2) << self.log2spc) + sec

    def fat_next(self, clus):
        lba = self.fat_lba + (clus >> 7)
        off = (clus & 127) * 4
        s = self.rd(lba)
        v = struct.unpack_from('<I', s, off)[0] & 0x0FFFFFFF
        self.log('FAT[%d] = 0x%08X (%s)' % (clus, v, 'EOC' if v >= EOC else 'next %d' % v))
        return v

    # ---------------- 根目录扫描 ----------------
    def scan_dir(self):
        self.files = []
        self.count = 0
        clus = self.root_clus
        sec = 0
        while True:
            s = self.rd(self.clus_lba(clus, sec))
            for e in range(16):
                ent = s[e * 32:(e + 1) * 32]
                n0 = ent[0]
                attr = ent[11]
                name = ent[0:11].decode('latin1')
                if n0 == 0x00:
                    self.log('end of directory (0x00) at clus %d sec %d ent %d' % (clus, sec, e))
                    return
                if n0 == 0xE5:
                    continue
                if attr == 0x0F:
                    self.log('  skip LFN entry')
                    continue
                if attr & 0x08:
                    self.log('  skip volume label %r' % name)
                    continue
                if attr & 0x10:
                    self.log('  skip sub directory %r' % name)
                    continue
                if n0 == 0x2E:
                    continue
                if ent[8:11].upper() in (b'BMP',) and ent[8:11] == b'BMP':
                    key = self._key(ent)
                    ch = (ent[21] << 24) | (ent[20] << 16) | (ent[27] << 8) | ent[26]
                    sz = struct.unpack_from('<I', ent, 28)[0]
                    if self.count < MAXF:
                        self.files.append((key, ch, sz, name))
                        self.count += 1
                        self.log('  + file %r key=0x%04X clus=%d size=%d'
                                 % (name, key, ch, sz))
                    if self.count >= MAXF:
                        self.log('list full (%d)' % MAXF)
                        return
            if sec + 1 >= self.spc:
                nxt = self.fat_next(clus)
                if nxt >= EOC:
                    return
                clus, sec = nxt, 0
            else:
                sec += 1

    @staticmethod
    def _key(ent):
        if ent[0:3] == b'IMG' and all(0x30 <= b <= 0x39 for b in ent[3:7]):
            return ((ent[3] & 0xF) << 12) | ((ent[4] & 0xF) << 8) | \
                   ((ent[5] & 0xF) << 4) | (ent[6] & 0xF)
        return 0xFFFF

    # ---------------- 串行 min/max 扫描 ----------------
    def pick(self, mode, ref):
        """mode 0 = next(ascending), 1 = previous; 返回 (idx, key)"""
        have_gt = False
        gt = 0xFFFF if mode == 0 else 0x0000
        gt_i = 0
        have_all = False
        allv = 0xFFFF if mode == 0 else 0x0000
        all_i = 0
        for i in range(self.count):
            k = self.files[i][0]
            if mode == 0:
                if k > ref and (not have_gt or k < gt):
                    gt, gt_i, have_gt = k, i, True
                if not have_all or k < allv:
                    allv, all_i, have_all = k, i, True
            else:
                if k < ref and (not have_gt or k > gt):
                    gt, gt_i, have_gt = k, i, True
                if not have_all or k > allv:
                    allv, all_i, have_all = k, i, True
        idx = gt_i if have_gt else all_i
        key = gt if have_gt else allv
        self.log('pick mode=%d ref=0x%04X -> idx=%d key=0x%04X' % (mode, ref, idx, key))
        return idx, key

    # ---------------- 加载一张 BMP ----------------
    def load(self, idx, flush_on_error=False):
        key, clus, size, name = self.files[idx]
        self.cur_key = key
        self.cur_idx = idx
        # 文件首扇区（= 首簇的扇区 0）
        s0 = self.rd(self.clus_lba(clus, 0))
        hdr = s0[0:34]
        bf_off = struct.unpack_from('<I', hdr, 10)[0]
        bi_size = struct.unpack_from('<I', hdr, 14)[0]
        bi_w = struct.unpack_from('<i', hdr, 18)[0]
        bi_h = struct.unpack_from('<i', hdr, 22)[0]
        bpp = struct.unpack_from('<H', hdr, 28)[0]
        comp = struct.unpack_from('<I', hdr, 30)[0]
        ok = (hdr[0:2] == b'BM' and bi_size == 40 and bi_w == W and
              abs(bi_h) == H and bpp == 24 and comp == 0 and bf_off >= HDR_BYTES)
        self.log('header %r: bfOff=%d size=%d %dx%d bpp=%d comp=%d -> %s'
                 % (name, bf_off, bi_size, bi_w, bi_h, bpp, comp, 'OK' if ok else 'REJECT'))
        if not ok:
            self.err = 4
            return False
        if size and size < bf_off + PIX_BYTES:
            self.err = 6
            self.log('short file size %d < %d (padded black)' % (size, bf_off + PIX_BYTES))
        self.w.start(bottom_up=(bi_h > 0))
        self.pixels = 0
        skip = bf_off
        pixleft = PIX_BYTES
        sec = 0
        phase = 0
        b = [0, 0, 0]
        total_secs = 0
        while pixleft > 0:
            if skip >= SEC:
                skip -= SEC
                want = 0
                off = 0
            else:
                off = skip
                want = min(SEC - skip, pixleft)
                skip = 0
            if want:
                s = self.rd(self.clus_lba(clus, sec))
                total_secs += 1
                for i in range(off, off + want):
                    b[phase] = s[i]
                    phase += 1
                    if phase == 3:
                        phase = 0
                        word = (b[2] << 16) | (b[1] << 8) | b[0]
                        self.w.push(word)
                        self.pixels += 1
                pixleft -= want
            # 扇区/簇推进（对应 RTL 的 S_ADV，先判 pixleft==0）
            if pixleft == 0:
                break
            if sec + 1 >= self.spc:
                nxt = self.fat_next(clus)
                if nxt >= EOC:
                    self.err = 5
                    self.log('chain ends early: %d pixel bytes missing' % pixleft)
                    # RTL：pixleft 置 1 触发 O_wr_flush，用黑色补齐
                    while pixleft > 0:
                        self.w.push(0x000000)
                        self.pixels += 1
                        pixleft -= 3
                    break
                clus, sec = nxt, 0
            else:
                sec += 1
        self.log('pixels=%d sectors=%d bursts=%d' % (self.pixels, total_secs, self.w.bursts))
        return True

    # ---------------- M1 回退图案 ----------------
    def run_pattern(self):
        self.pattern = True
        had_err = self.err
        self.w.start(bottom_up=False)
        for y in range(H):
            for x in range(W):
                if x < 8 or x >= W - 8 or y < 8 or y >= H - 8:
                    c = 0x00FF00
                else:
                    c = ((x >> 2) << 16) | ((y >> 1) << 8) | 0x40
                self.w.push(c)
        if not had_err:
            self.err = 3

    # ---------------- 上电流程 ----------------
    def boot(self):
        if not self.mount():
            self.run_pattern()
            return
        self.scan_dir()
        if self.count == 0:
            self.run_pattern()
            return
        idx, key = self.pick(0, 0xFFFF)
        self.load(idx)


# ==========================================================================
#  4) 检查
# ==========================================================================
def page_to_rgb(page, base):
    """把页内容还原成自上而下的 RGB 字节流"""
    out = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            v = page.get(base + y * W + x, 0)
            i = (y * W + x) * 3
            out[i] = (v >> 16) & 0xFF
            out[i + 1] = (v >> 8) & 0xFF
            out[i + 2] = v & 0xFF
    return bytes(out)


def check_writer(tag, m, expect_img=None):
    w = m.w
    base = m.page_base
    check('%s: 写满一整页 (307200 字)' % tag, w.writes == W * H, 'writes=%d' % w.writes)
    check('%s: 没有重复写同一地址' % tag, w.dups == 0, 'dups=%d' % w.dups)
    addrs = sorted(w.page.keys())
    want = list(range(base, base + W * H))
    check('%s: 地址覆盖 base..base+307199 连续无缺口' % tag, addrs == want,
          'n=%d' % len(addrs))
    n_rows = H if not m.pattern else H
    check('%s: 每行一次 WR1_LOAD，共 %d 次' % (tag, n_rows),
          len(w.loads) == n_rows, 'loads=%d' % len(w.loads))
    check('%s: 所有 LOAD 地址 128 字对齐' % tag,
          all(a % 128 == 0 for a in w.loads))
    rows = sorted((a - base) // W for a in w.loads)
    check('%s: 每个行地址只 LOAD 一次且覆盖 0..479' % tag, rows == list(range(H)))
    check('%s: 每行恰好 5 个 128 字突发' % tag, all(b == 5 for b in w.row_bursts),
          'set=%s' % sorted(set(w.row_bursts)))
    check('%s: 每个行边界处写 FIFO 残留为 0' % tag,
          all(f == 0 for f in w.row_end_fifo),
          'max residual=%d' % (max(w.row_end_fifo) if w.row_end_fifo else -1))
    worst = 3 * (138 + 2 * 138)         # 3 个待发突发 × (突发 + 2 个读突发插队)
    check('%s: DRAIN 等待上界 3 个突发 (%d 拍) < DRAIN=%d' % (tag, worst, DRAIN_CLOCKS),
          worst < DRAIN_CLOCKS)
    if expect_img is not None:
        got = page_to_rgb(w.page, base)
        check('%s: 页内容 == 源图（方向/颜色/BGR→RGB 正确）' % tag, got == expect_img,
              'first diff %s' % first_diff(got, expect_img))


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return 'byte %d: got %d want %d' % (i, a[i], b[i])
    if len(a) != len(b):
        return 'length %d vs %d' % (len(a), len(b))
    return '-'


# ==========================================================================
#  场景
# ==========================================================================
def scenario_basic(verbose=False):
    print('\n== 场景 1：一张标准 IMG0001.BMP（spc=8，碎片无关，连续簇） ==')
    img = test_image('a')
    bmp = make_bmp(img)
    b = Fat32Builder(spc=8, nclusters=640)
    b.add_file('IMG0001.BMP', bmp)
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s1: 挂载成功', m.err in (0, 6), 'err=%d' % m.err)
    check('s1: 找到 1 个文件', m.count == 1, 'count=%d' % m.count)
    check('s1: 解码 307200 个像素', m.pixels == W * H, 'pixels=%d' % m.pixels)
    check_writer('s1', m, img)
    print('    扇区读取次数 = %d，估算加载时间 = %.3f s'
          % (m.sectors, m.sectors * 190e-6))
    return m


def scenario_fragmented(verbose=False):
    print('\n== 场景 2：碎片簇链（每 2 个簇跳一次）+ LFN + 删除项 + 子目录 + 非 BMP ==')
    img = test_image('b')
    bmp = make_bmp(img)
    b = Fat32Builder(spc=8, nclusters=1024)
    # 先把碎片链的簇号算出来：226 个簇，两两一组交叉
    n = (len(bmp) + 8 * SEC - 1) // (8 * SEC)
    base = b.next_free
    chain = []
    for i in range(0, n, 2):
        chain.append(base + 300 + i)
        if i + 1 < n:
            chain.append(base + i + 1)
    b.next_free = base + 400 + n
    assert b.next_free + 8 < b.nclusters, (b.next_free, b.nclusters)
    b.add_deleted('IMG0009.BMP')
    b.add_dir('SUBDIR')
    b.add_file('README.TXT', b'just some text, not a bmp' * 10)
    b.add_file('IMG0002.BMP', bmp, chain=chain, longname='long file name test.bmp')
    b.add_file('IMG0003.BMP', bmp[:200])          # 长度明显不够的坏文件
    b.add_file('IMG0004.BMP', make_bmp(img, bad_bm=True))    # 'XX' 开头
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s2: 挂载成功', m.err in (0, 6), 'err=%d' % m.err)
    check('s2: 索引到 3 个 BMP（跳过 LFN/删除项/子目录/非 BMP）', m.count == 3,
          'count=%d names=%s' % (m.count, [f[3] for f in m.files]))
    check('s2: 上电选到编号最小的 BMP0002',
          m.files[m.cur_idx][3].startswith('IMG0002'),
          'idx=%d key=%d name=%r' % (m.cur_idx, m.cur_key, m.files[m.cur_idx][3]))
    # 直接指定加载碎片链那张，验证簇映射
    idx = [i for i, f in enumerate(m.files) if f[3].startswith('IMG0002')][0]
    ok = m.load(idx)
    check('s2: 碎片链文件加载成功', ok and m.err in (0, 6), 'err=%d' % m.err)
    check('s2: 像素数正确', m.pixels == W * H, 'pixels=%d' % m.pixels)
    check_writer('s2', m, img)
    print('    扇区读取次数 = %d（含 FAT 链 walk），估算 %.3f s'
          % (m.sectors, m.sectors * 190e-6))
    # next / prev 扫描（按编号）
    i1, k1 = m.pick(0, m.files[idx][0])
    check('s2: next 从 IMG0002 -> IMG0003', m.files[i1][3].startswith('IMG0003'),
          'key=0x%04X' % k1)
    i2, k2 = m.pick(1, m.files[idx][0])
    check('s2: prev 从 IMG0002 回绕到最大的 IMG0004',
          m.files[i2][3].startswith('IMG0004'), 'key=0x%04X' % k2)
    return m


def scenario_palette(verbose=False):
    print('\n== 场景 3：bfOffBits > 512（1078 字节调色板前缀，要按扇区跳过） ==')
    img = test_image('c')
    bmp = make_bmp(img, bf_off=1078, palette_bytes=1078 - HDR_BYTES)
    b = Fat32Builder(spc=1, nclusters=3000)     # spc=1：最坏情况的簇/扇区换算
    b.add_file('IMG0001.BMP', bmp)
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s3: 挂载成功', m.err in (0, 6), 'err=%d' % m.err)
    check('s3: 像素数正确', m.pixels == W * H, 'pixels=%d' % m.pixels)
    check_writer('s3', m, img)
    print('    扇区读取次数 = %d，估算 %.3f s（spc=1 时 FAT 链读得最频繁）'
          % (m.sectors, m.sectors * 190e-6))
    return m


def scenario_no_bmp(verbose=False):
    print('\n== 场景 4：卡里没有 BMP -> 回退 M1 测试图案 ==')
    b = Fat32Builder(spc=8, nclusters=256)
    b.add_file('README.TXT', b'hello' * 100)
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s4: 挂载成功但 0 个 BMP', m.count == 0, 'count=%d' % m.count)
    check('s4: 进入图案回退', m.pattern, 'pattern=%s' % m.pattern)
    check('s4: err=3（没有 BMP）', m.err == 3, 'err=%d' % m.err)
    check_writer('s4', m)
    w = m.w
    corner = w.page[w.base + 0]
    check('s4: 左上角是绿色边框 0x00FF00', corner == 0x00FF00, '0x%06X' % corner)
    mid = w.page[w.base + 240 * W + 320]
    check('s4: 中心是渐变 {x[9:2],y[8:1],0x40}',
          mid == (((320 >> 2) << 16) | ((240 >> 1) << 8) | 0x40), '0x%06X' % mid)
    return m


def scenario_not_fat32(verbose=False):
    print('\n== 场景 5：不是 FAT32（FAT16 的 BPB）-> 挂载失败 -> 图案 ==')
    img = test_image('d')
    bmp = make_bmp(img)
    b = Fat32Builder(spc=8, nclusters=256)
    b.add_file('IMG0001.BMP', bmp)
    raw = bytearray(b.build())
    bl = b.part_lba * SEC
    struct.pack_into('<H', raw, bl + 32, 8)      # FATSz16 = 8 -> 不是 FAT32
    struct.pack_into('<I', raw, bl + 36, 0)      # FATSz32 = 0
    disk = Disk(bytes(raw))
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s5: 拒绝 FAT16 (err=2)', m.err == 2, 'err=%d' % m.err)
    check('s5: 回退图案', m.pattern)
    check_writer('s5', m)
    return m


def scenario_truncated(verbose=False):
    print('\n== 场景 6：文件链提前结束（截断的卡）-> 剩余像素填黑 ==')
    img = test_image('e')
    bmp = make_bmp(img)
    b = Fat32Builder(spc=8, nclusters=640)
    n = (len(bmp) + 8 * SEC - 1) // (8 * SEC)
    cl = b.alloc(n)
    for i, c in enumerate(cl):
        chunk = bmp[i * 8 * SEC:(i + 1) * 8 * SEC]
        b.data[c][0:len(chunk)] = chunk
    # 只把前 100 个簇连起来，然后 EOC
    for a, bb in zip(cl[:99], cl[1:100]):
        b.fat[a] = bb
    b.fat[cl[99]] = 0x0FFFFFFF
    b.add_entry(b.name83('IMG0001.BMP'), 0x20, cl[0], len(bmp))
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.boot()
    check('s6: 检出链提前结束 err=5', m.err == 5, 'err=%d' % m.err)
    check_writer('s6', m)
    w = m.w
    # 图的上方（页 0 行起）来自文件末尾，应该还在；下方变黑
    nblack = sum(1 for v in w.page.values() if v == 0)
    check('s6: 缺失部分被填黑', nblack > 0, 'black words = %d' % nblack)
    return m


def scenario_16_files(verbose=False):
    print('\n== 场景 7：根目录超过 16 个 BMP（MAXF=16 截断） ==')
    img = test_image('f')
    b = Fat32Builder(spc=8, nclusters=4096)
    for i in range(1, 21):
        b.add_file('IMG%04d.BMP' % i, make_bmp(img, width=W, height=H)[:0] + b'')
    # 上面写的都是 0 字节的空文件，只关心目录项被收集
    disk = Disk(b.build())
    m = RtlModel(disk, verbose=verbose)
    m.mount()
    m.scan_dir()
    check('s7: 目录里 20 个 BMP，只收 16 个', m.count == MAXF, 'count=%d' % m.count)
    check('s7: 收满即停止扫描', m.count == MAXF)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--dump-page', action='store_true')
    a = ap.parse_args()

    print('M2 FAT32/BMP 离线模型  (RTL: rtl/m2_fat_bmp.v, rtl/m2_page_wr.v)')
    print('常量: %dx%d, %d bit, 页 = %d 字 = 0x%X, DRAIN=%d 拍'
          % (W, H, 24, W * H, W * H, DRAIN_CLOCKS))

    ms = []
    ms.append(scenario_basic(a.verbose))
    ms.append(scenario_fragmented(a.verbose))
    ms.append(scenario_palette(a.verbose))
    ms.append(scenario_no_bmp(a.verbose))
    ms.append(scenario_not_fat32(a.verbose))
    ms.append(scenario_truncated(a.verbose))
    scenario_16_files(a.verbose)

    if a.dump_page:
        try:
            from PIL import Image
            rgb = page_to_rgb(ms[0].w.page, ms[0].page_base)
            Image.frombytes('RGB', (W, H), rgb).save('page_dump.png')
            print('\n已写出 page_dump.png（场景 1 解码结果）')
        except ImportError:
            print('\n需要 Pillow 才能 --dump-page')

    print('\n' + '=' * 74)
    bad = [r for r in RESULTS if not r[0]]
    print('共 %d 项检查：%d PASS / %d FAIL' % (len(RESULTS), len(RESULTS) - len(bad), len(bad)))
    for _, n, d in bad:
        print('  FAIL: %s  %s' % (n, d))
    print('=' * 74)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
