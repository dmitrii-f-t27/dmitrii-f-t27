// SPDX-License-Identifier: Apache-2.0
// TrinityOS Ring 0.5 — референс-эмуляция MMIO-устройств CLK/INP/NET/DISP.
// Исполняемая форма спек trinityos/specs/os/*.t27: каждый GOLDEN оттуда
// закреплён тестом здесь. Интеграция с TRI-27: LOAD/STORE executor'а при
// byte_addr >= MMIO_BASE_BYTE зовут Mmio.load/store вместо памяти.
// φ² + 1/φ² = 3 | TRINITY

const std = @import("std");

// ---- os-mmio-map -----------------------------------------------------------

pub const MEMORY_SIZE_WORDS: u32 = 19683; // 3^9
// ADR-M1: immediate LD/ST — 15 бит со знаком, адресуемы слова 0..16383,
// поэтому окно сидит на 2*3^8, а не в верху памяти (см. specs/os/mmio_map.t27)
pub const MMIO_BASE_WORD: u32 = 13122; // 2 * 3^8
pub const MMIO_END_WORD: u32 = 15309; // 13122 + 3^7
pub const MMIO_BASE_BYTE: u32 = MMIO_BASE_WORD * 4;
pub const DEV_BLOCK_WORDS: u32 = 243; // 3^5

pub const CLK_BASE: u32 = MMIO_BASE_WORD + 0;
pub const INP_BASE: u32 = MMIO_BASE_WORD + 243;
pub const NET_BASE: u32 = MMIO_BASE_WORD + 486;
pub const DISP_REG_BASE: u32 = MMIO_BASE_WORD + 729;
pub const DISP_RING_BASE: u32 = MMIO_BASE_WORD + 972;
pub const DISP_RING_WORDS: u32 = 1215; // 5 * 3^5

pub fn isMmioWord(word_addr: u32) bool {
    return word_addr >= MMIO_BASE_WORD and word_addr < MMIO_END_WORD;
}

pub fn isMmioByte(byte_addr: u32) bool {
    return byte_addr >= MMIO_BASE_BYTE and byte_addr < MMIO_END_WORD * 4;
}

// ---- os-dev-clk ------------------------------------------------------------

pub const CLK_R_UNIX_LO: u32 = 0;
pub const CLK_R_UNIX_HI: u32 = 1;
pub const CLK_R_UPTIME_MS_LO: u32 = 2;
pub const CLK_R_UPTIME_MS_HI: u32 = 3;
pub const CLK_R_TICK_HZ: u32 = 4;

// ---- os-dev-inp ------------------------------------------------------------

pub const INP_R_HEAD: u32 = 0;
pub const INP_R_TAIL: u32 = 1;
pub const INP_R_CAPACITY: u32 = 2;
pub const INP_R_RING: u32 = 3;
pub const INP_RING_CAPACITY: u32 = 24;

pub const EV_KEY_DOWN: u8 = 1;
pub const EV_KEY_UP: u8 = 2;
pub const EV_PTR_MOVE: u8 = 3;
pub const EV_PTR_DOWN: u8 = 4;
pub const EV_PTR_UP: u8 = 5;

pub const InputEvent = struct {
    ev_type: u8,
    code: u8,
    x: i16,
    y: i16,
};

// ---- os-dev-net ------------------------------------------------------------

pub const NET_R_DOORBELL: u32 = 0;
pub const NET_R_STATUS: u32 = 1;
pub const NET_R_TOPIC: u32 = 2;
pub const NET_R_PARAM0: u32 = 3;
pub const NET_R_PARAM1: u32 = 4;
pub const NET_R_PARAM2: u32 = 5;
pub const NET_R_PARAM3: u32 = 6;
pub const NET_R_DST_WORD: u32 = 7;
pub const NET_R_DST_CAP_WORDS: u32 = 8;
pub const NET_R_COUNT: u32 = 9;
pub const NET_R_SEQ: u32 = 10;

pub const NET_ST_IDLE: u32 = 0;
pub const NET_ST_BUSY: u32 = 1;
pub const NET_ST_READY: u32 = 2;
pub const NET_ST_ERROR: u32 = 3;

pub const TOPIC_QUAKES: u32 = 1;
pub const TOPIC_ADSB: u32 = 2;
// M2 (ADR-M2): screen-space записи, движение моделирует мост; PARAM1 = шаг
pub const TOPIC_ADSB_XY: u32 = 4;
pub const TOPIC_SATS_XY: u32 = 5;

/// Одна запись результата NET — всегда 4 слова.
pub const Rec4 = [4]u32;

/// Мост: заполняет out записями топика, возвращает их число.
/// null-результат — неизвестный топик (STATUS=ERROR).
pub const NetBackend = *const fn (topic: u32, params: [4]u32, seq: u32, out: []Rec4) ?u32;

// ---- os-dev-disp -----------------------------------------------------------

pub const VIRT_W: u32 = 1458;
pub const VIRT_H: u32 = 729;

pub const DISP_R_CTRL: u32 = 0;
pub const DISP_R_STATUS: u32 = 1;
pub const DISP_R_HEAD: u32 = 2;
pub const DISP_R_TAIL: u32 = 3;
pub const DISP_R_FRAME_ID: u32 = 4;
pub const DISP_R_LAYER_MASK: u32 = 5;

pub const DISP_CTRL_COMMIT: u32 = 1;

pub const OP_NOP: u8 = 0;
pub const OP_CLEAR: u8 = 1;
pub const OP_POINT: u8 = 2;
pub const OP_MOVE_TO: u8 = 3;
pub const OP_LINE_TO: u8 = 4;
pub const OP_GLYPH: u8 = 5;

pub const DispCmd = struct {
    op: u8,
    layer: u8,
    color: u8,
    size: u8,
    x: i16,
    y: i16,
};

pub const MAX_FRAME_CMDS: u32 = DISP_RING_WORDS / 2; // 607

pub const Frame = struct {
    frame_id: u32,
    layer_mask: u32,
    count: u32,
    cmds: [MAX_FRAME_CMDS]DispCmd,
};

// ---- Устройства как одно MMIO-состояние ------------------------------------

pub const Mmio = struct {
    // CLK
    unix_seconds: u64 = 0,
    uptime_ms: u64 = 0,
    tick_hz: u32 = 1000,
    clk_unix_hi_latch: u32 = 0,
    clk_uptime_hi_latch: u32 = 0,

    // INP
    inp_head: u32 = 0,
    inp_tail: u32 = 0,
    inp_ring: [INP_RING_CAPACITY][2]u32 = @splat(.{ 0, 0 }),

    // NET
    net_status: u32 = NET_ST_IDLE,
    net_topic: u32 = 0,
    net_params: [4]u32 = @splat(0),
    net_dst_word: u32 = 0,
    net_dst_cap_words: u32 = 0,
    net_count: u32 = 0,
    net_seq: u32 = 0,
    net_backend: ?NetBackend = null,

    // DISP
    disp_head: u32 = 0, // словесный индекс в кольце
    disp_tail: u32 = 0,
    disp_frame_id: u32 = 0,
    disp_layer_mask: u32 = 0x07FF_FFFF, // все 27 слоёв видимы
    disp_ring: [DISP_RING_WORDS]u32 = @splat(0),
    frame: Frame = .{ .frame_id = 0, .layer_mask = 0, .count = 0, .cmds = undefined },
    frame_ready: bool = false,
    /// Носитель может подписаться на каждый COMMIT (раннер собирает все кадры)
    on_frame: ?*const fn (ctx: ?*anyopaque, frame: *const Frame) void = null,
    on_frame_ctx: ?*anyopaque = null,

    // -- гостевые обращения (из LOAD/STORE executor'а) -----------------------

    pub fn load(self: *Mmio, word_addr: u32) u32 {
        if (!isMmioWord(word_addr)) return 0;
        if (word_addr >= DISP_RING_BASE) {
            return self.disp_ring[word_addr - DISP_RING_BASE];
        }
        if (word_addr >= DISP_REG_BASE) {
            return switch (word_addr - DISP_REG_BASE) {
                DISP_R_CTRL => 0,
                DISP_R_STATUS => 1,
                DISP_R_HEAD => self.disp_head,
                DISP_R_TAIL => self.disp_tail,
                DISP_R_FRAME_ID => self.disp_frame_id,
                DISP_R_LAYER_MASK => self.disp_layer_mask,
                else => 0,
            };
        }
        if (word_addr >= NET_BASE) {
            return switch (word_addr - NET_BASE) {
                NET_R_DOORBELL => 0,
                NET_R_STATUS => self.net_status,
                NET_R_TOPIC => self.net_topic,
                NET_R_PARAM0 => self.net_params[0],
                NET_R_PARAM1 => self.net_params[1],
                NET_R_PARAM2 => self.net_params[2],
                NET_R_PARAM3 => self.net_params[3],
                NET_R_DST_WORD => self.net_dst_word,
                NET_R_DST_CAP_WORDS => self.net_dst_cap_words,
                NET_R_COUNT => self.net_count,
                NET_R_SEQ => self.net_seq,
                else => 0,
            };
        }
        if (word_addr >= INP_BASE) {
            const off = word_addr - INP_BASE;
            if (off == INP_R_HEAD) return self.inp_head;
            if (off == INP_R_TAIL) return self.inp_tail;
            if (off == INP_R_CAPACITY) return INP_RING_CAPACITY;
            if (off >= INP_R_RING and off < INP_R_RING + INP_RING_CAPACITY * 2) {
                const slot = (off - INP_R_RING) / 2;
                return self.inp_ring[slot][(off - INP_R_RING) % 2];
            }
            return 0;
        }
        // CLK: snapshot-протокол — чтение LO защёлкивает HI
        return switch (word_addr - CLK_BASE) {
            CLK_R_UNIX_LO => blk: {
                self.clk_unix_hi_latch = @truncate(self.unix_seconds >> 32);
                break :blk @truncate(self.unix_seconds);
            },
            CLK_R_UNIX_HI => self.clk_unix_hi_latch,
            CLK_R_UPTIME_MS_LO => blk: {
                self.clk_uptime_hi_latch = @truncate(self.uptime_ms >> 32);
                break :blk @truncate(self.uptime_ms);
            },
            CLK_R_UPTIME_MS_HI => self.clk_uptime_hi_latch,
            CLK_R_TICK_HZ => self.tick_hz,
            else => 0,
        };
    }

    /// ram — байтовая память гостя (та же, что у executor'а); NET пишет туда.
    pub fn store(self: *Mmio, word_addr: u32, value: u32, ram: []u8) void {
        if (!isMmioWord(word_addr)) return;
        if (word_addr >= DISP_RING_BASE) {
            self.disp_ring[word_addr - DISP_RING_BASE] = value;
            return;
        }
        if (word_addr >= DISP_REG_BASE) {
            switch (word_addr - DISP_REG_BASE) {
                DISP_R_CTRL => if (value & DISP_CTRL_COMMIT != 0) self.dispCommit(),
                DISP_R_TAIL => self.disp_tail = value % DISP_RING_WORDS,
                DISP_R_LAYER_MASK => self.disp_layer_mask = value & 0x07FF_FFFF,
                else => {}, // RO-регистры — no-op (инвариант I3-стиль)
            }
            return;
        }
        if (word_addr >= NET_BASE) {
            switch (word_addr - NET_BASE) {
                NET_R_DOORBELL => if (value == 1) self.netRequest(ram),
                NET_R_TOPIC => self.net_topic = value,
                NET_R_PARAM0 => self.net_params[0] = value,
                NET_R_PARAM1 => self.net_params[1] = value,
                NET_R_PARAM2 => self.net_params[2] = value,
                NET_R_PARAM3 => self.net_params[3] = value,
                NET_R_DST_WORD => self.net_dst_word = value,
                NET_R_DST_CAP_WORDS => self.net_dst_cap_words = value,
                else => {},
            }
            return;
        }
        if (word_addr >= INP_BASE) {
            if (word_addr - INP_BASE == INP_R_TAIL) self.inp_tail = value;
            return;
        }
        // CLK: RO — гость может писать безопасно (G-CLK-2)
    }

    // -- INP: сторона носителя ----------------------------------------------

    pub fn pushInput(self: *Mmio, ev: InputEvent) bool {
        if (self.inp_head -% self.inp_tail >= INP_RING_CAPACITY - 1) return false;
        const slot = self.inp_head % INP_RING_CAPACITY;
        self.inp_ring[slot][0] =
            @as(u32, ev.ev_type) | @as(u32, ev.code) << 8;
        self.inp_ring[slot][1] =
            @as(u32, @as(u16, @bitCast(ev.x))) | @as(u32, @as(u16, @bitCast(ev.y))) << 16;
        self.inp_head +%= 1;
        return true;
    }

    // -- NET: исполнение запроса ---------------------------------------------

    fn netRequest(self: *Mmio, ram: []u8) void {
        if (self.net_status == NET_ST_BUSY) return; // N2
        self.net_status = NET_ST_BUSY;
        self.net_count = 0;

        const cap_recs = self.net_dst_cap_words / 4;
        // N4: буфер не смеет пересекать MMIO-окно
        if (self.net_dst_word < MMIO_END_WORD and
            self.net_dst_word + self.net_dst_cap_words > MMIO_BASE_WORD)
        {
            self.net_seq +%= 1;
            self.net_status = NET_ST_ERROR;
            return;
        }
        var recs: [256]Rec4 = undefined;
        const backend = self.net_backend orelse {
            self.net_seq +%= 1;
            self.net_status = NET_ST_ERROR;
            return;
        };
        const produced = backend(self.net_topic, self.net_params, self.net_seq, recs[0..]) orelse {
            self.net_seq +%= 1;
            self.net_status = NET_ST_ERROR;
            return;
        };
        const n: u32 = @min(produced, cap_recs); // усечение: COUNT — истина
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var w: u32 = 0;
            while (w < 4) : (w += 1) {
                const byte_addr = (self.net_dst_word + i * 4 + w) * 4;
                std.mem.writeInt(u32, ram[byte_addr..][0..4], recs[i][w], .little);
            }
        }
        self.net_count = n;
        self.net_seq +%= 1;
        self.net_status = NET_ST_READY; // N3: после последней записи в ОЗУ
    }

    // -- DISP: защёлкивание кадра ---------------------------------------------

    fn dispCommit(self: *Mmio) void {
        var count: u32 = 0;
        var idx = self.disp_head;
        while (idx != self.disp_tail) {
            const w0 = self.disp_ring[idx];
            const w1 = self.disp_ring[(idx + 1) % DISP_RING_WORDS];
            idx = (idx + 2) % DISP_RING_WORDS;
            const op: u8 = @truncate(w0);
            const layer: u8 = @truncate(w0 >> 8);
            const color: u8 = @truncate(w0 >> 16);
            if (op > OP_GLYPH) continue; // D3
            if (layer > 26 or color > 26) continue; // D4
            self.frame.cmds[count] = .{
                .op = op,
                .layer = layer,
                .color = color,
                .size = @truncate(w0 >> 24),
                .x = @bitCast(@as(u16, @truncate(w1))),
                .y = @bitCast(@as(u16, @truncate(w1 >> 16))),
            };
            count += 1;
        }
        self.disp_head = self.disp_tail;
        self.disp_frame_id += 1;
        self.frame.frame_id = self.disp_frame_id;
        self.frame.layer_mask = self.disp_layer_mask;
        self.frame.count = count;
        self.frame_ready = true;
        if (self.on_frame) |cb| cb(self.on_frame_ctx, &self.frame);
    }

    /// Носитель забирает последний защёлкнутый кадр (обсервер/рендер).
    pub fn takeFrame(self: *Mmio) ?*const Frame {
        if (!self.frame_ready) return null;
        self.frame_ready = false;
        return &self.frame;
    }

    // -- Удобства гостя (в реальном TRI-27 это просто STORE-инструкции) ------

    pub fn guestPushCmd(self: *Mmio, cmd: DispCmd, ram: []u8) void {
        const t = self.disp_tail;
        const w0 = @as(u32, cmd.op) | @as(u32, cmd.layer) << 8 |
            @as(u32, cmd.color) << 16 | @as(u32, cmd.size) << 24;
        const w1 = @as(u32, @as(u16, @bitCast(cmd.x))) |
            @as(u32, @as(u16, @bitCast(cmd.y))) << 16;
        self.store(DISP_RING_BASE + t, w0, ram);
        self.store(DISP_RING_BASE + (t + 1) % DISP_RING_WORDS, w1, ram);
        self.store(DISP_REG_BASE + DISP_R_TAIL, (t + 2) % DISP_RING_WORDS, ram);
    }
};

// ---- Канонический мост Workbench: датасет "golden-3" -----------------------
// Детерминированные данные для голденов и демо. Живой мост (fetch к USGS /
// OpenSky) подключается на M1 тем же интерфейсом NetBackend.

const GOLDEN_QUAKES = [_]struct { lat_e4: i32, lon_e4: i32, mag_x10: u16, depth_km: u16, age_min: u16 }{
    .{ .lat_e4 = 352476, .lon_e4 = 1391026, .mag_x10 = 61, .depth_km = 30, .age_min = 12 }, // Токио
    .{ .lat_e4 = -334489, .lon_e4 = -706693, .mag_x10 = 55, .depth_km = 90, .age_min = 45 }, // Сантьяго
    .{ .lat_e4 = 387223, .lon_e4 = -91393, .mag_x10 = 50, .depth_km = 15, .age_min = 120 }, // Лиссабон
    .{ .lat_e4 = 641353, .lon_e4 = -214895, .mag_x10 = 32, .depth_km = 5, .age_min = 200 }, // Рейкьявик (слабое)
};

const GOLDEN_ADSB = [_]struct { lat_e4: i32, lon_e4: i32, alt_m: u16, hdg_deg: u16, id_hash: u32 }{
    .{ .lat_e4 = 513300, .lon_e4 = 1550, .alt_m = 11000, .hdg_deg = 270, .id_hash = 0xA1 },
    .{ .lat_e4 = 487800, .lon_e4 = 23500, .alt_m = 10600, .hdg_deg = 90, .id_hash = 0xA2 },
    .{ .lat_e4 = 403000, .lon_e4 = -740000, .alt_m = 9800, .hdg_deg = 45, .id_hash = 0xA3 },
    .{ .lat_e4 = -237000, .lon_e4 = -466000, .alt_m = 11300, .hdg_deg = 180, .id_hash = 0xA4 },
    .{ .lat_e4 = 13500, .lon_e4 = 1038000, .alt_m = 12000, .hdg_deg = 315, .id_hash = 0xA5 },
};

pub fn goldenBackend(topic: u32, params: [4]u32, seq: u32, out: []Rec4) ?u32 {
    switch (topic) {
        TOPIC_QUAKES => {
            const min_mag: u32 = params[0];
            var n: u32 = 0;
            for (GOLDEN_QUAKES) |q| {
                if (q.mag_x10 < min_mag) continue;
                if (n >= out.len) break;
                out[n] = .{
                    @bitCast(q.lat_e4),
                    @bitCast(q.lon_e4),
                    @as(u32, q.mag_x10) | @as(u32, q.depth_km) << 16,
                    @as(u32, q.age_min),
                };
                n += 1;
            }
            return n;
        },
        TOPIC_ADSB => {
            var n: u32 = 0;
            for (GOLDEN_ADSB) |a| {
                if (n >= out.len) break;
                // детерминированный дрейф по долготе от seq — «живые» борта
                const drift: i32 = @as(i32, @intCast(seq % 97)) * 27000;
                var lon = a.lon_e4 + drift;
                if (lon > 1800000) lon -= 3600000;
                out[n] = .{
                    @bitCast(a.lat_e4),
                    @bitCast(lon),
                    @as(u32, a.alt_m) | @as(u32, a.hdg_deg) << 16,
                    a.id_hash,
                };
                n += 1;
            }
            return n;
        },
        else => return null,
    }
}

// ---- Голдены из спек как тесты ---------------------------------------------

const expectEqual = std.testing.expectEqual;

test "G-MAP-1/2: границы MMIO-окна" {
    try expectEqual(false, isMmioWord(13121));
    try expectEqual(true, isMmioWord(13122));
    try expectEqual(true, isMmioWord(15308));
    try expectEqual(false, isMmioWord(15309));
    try expectEqual(false, isMmioByte(52484));
    try expectEqual(true, isMmioByte(52488));
    // M5: окно целиком в досягаемости 15-битного immediate LD/ST
    try expectEqual(true, MMIO_END_WORD - 1 <= 16383);
}

test "G-CLK-1/2: чтение времени, запись — no-op" {
    var m = Mmio{ .unix_seconds = 1_787_562_715, .uptime_ms = 12_345 };
    var ram = [_]u8{0} ** 16;
    try expectEqual(@as(u32, 1_787_562_715), m.load(CLK_BASE + CLK_R_UNIX_LO));
    try expectEqual(@as(u32, 0), m.load(CLK_BASE + CLK_R_UNIX_HI));
    try expectEqual(@as(u32, 12_345), m.load(CLK_BASE + CLK_R_UPTIME_MS_LO));
    try expectEqual(@as(u32, 0), m.load(CLK_BASE + CLK_R_UPTIME_MS_HI));
    try expectEqual(@as(u32, 1000), m.load(CLK_BASE + CLK_R_TICK_HZ));
    m.store(CLK_BASE + CLK_R_UNIX_LO, 777, ram[0..]);
    try expectEqual(@as(u32, 1_787_562_715), m.load(CLK_BASE + CLK_R_UNIX_LO));
}

test "C2: пара LO/HI не рвётся на переносе (snapshot)" {
    var m = Mmio{ .unix_seconds = 0xFFFF_FFFF };
    const lo = m.load(CLK_BASE + CLK_R_UNIX_LO);
    m.unix_seconds += 1; // перенос между чтениями
    const hi = m.load(CLK_BASE + CLK_R_UNIX_HI);
    try expectEqual(@as(u32, 0xFFFF_FFFF), lo);
    try expectEqual(@as(u32, 0), hi); // HI защёлкнут на момент чтения LO
}

test "G-INP-1: два события в кольце" {
    var m = Mmio{};
    try expectEqual(true, m.pushInput(.{ .ev_type = EV_KEY_DOWN, .code = 'q', .x = 0, .y = 0 }));
    try expectEqual(true, m.pushInput(.{ .ev_type = EV_PTR_DOWN, .code = 1, .x = 729, .y = 364 }));
    try expectEqual(@as(u32, 2), m.load(INP_BASE + INP_R_HEAD));
    try expectEqual(@as(u32, 0), m.load(INP_BASE + INP_R_TAIL));
    try expectEqual(@as(u32, 1 | @as(u32, 'q') << 8), m.load(INP_BASE + INP_R_RING));
    try expectEqual(@as(u32, 0), m.load(INP_BASE + INP_R_RING + 1));
    try expectEqual(@as(u32, 4 | 1 << 8), m.load(INP_BASE + INP_R_RING + 2));
    try expectEqual(@as(u32, 729 | 364 << 16), m.load(INP_BASE + INP_R_RING + 3));
}

test "G-INP-2: кольцо вмещает CAP-1, лишнее отвергается" {
    var m = Mmio{};
    var i: u32 = 0;
    while (i < INP_RING_CAPACITY - 1) : (i += 1) {
        try expectEqual(true, m.pushInput(.{ .ev_type = EV_PTR_MOVE, .code = 0, .x = 0, .y = 0 }));
    }
    try expectEqual(false, m.pushInput(.{ .ev_type = EV_PTR_MOVE, .code = 0, .x = 0, .y = 0 }));
    try expectEqual(@as(u32, INP_RING_CAPACITY - 1), m.load(INP_BASE + INP_R_HEAD));
}

test "G-NET-1: quakes >=5.0 в буфер на 12 слов" {
    var m = Mmio{ .net_backend = goldenBackend };
    var ram = [_]u8{0} ** (MEMORY_SIZE_WORDS * 4);
    m.store(NET_BASE + NET_R_TOPIC, TOPIC_QUAKES, ram[0..]);
    m.store(NET_BASE + NET_R_PARAM0, 50, ram[0..]);
    m.store(NET_BASE + NET_R_DST_WORD, 1000, ram[0..]);
    m.store(NET_BASE + NET_R_DST_CAP_WORDS, 12, ram[0..]);
    m.store(NET_BASE + NET_R_DOORBELL, 1, ram[0..]);
    try expectEqual(@as(u32, NET_ST_READY), m.load(NET_BASE + NET_R_STATUS));
    try expectEqual(@as(u32, 3), m.load(NET_BASE + NET_R_COUNT));
    try expectEqual(@as(u32, 1), m.load(NET_BASE + NET_R_SEQ));
    try expectEqual(@as(i32, 352476), std.mem.readInt(i32, ram[4000..4004], .little));
    try expectEqual(@as(i32, 1391026), std.mem.readInt(i32, ram[4004..4008], .little));
    try expectEqual(@as(u16, 61), std.mem.readInt(u16, ram[4008..4010], .little));
}

test "G-NET-2: усечение по ёмкости буфера" {
    var m = Mmio{ .net_backend = goldenBackend };
    var ram = [_]u8{0} ** (MEMORY_SIZE_WORDS * 4);
    m.store(NET_BASE + NET_R_TOPIC, TOPIC_QUAKES, ram[0..]);
    m.store(NET_BASE + NET_R_PARAM0, 50, ram[0..]);
    m.store(NET_BASE + NET_R_DST_WORD, 1000, ram[0..]);
    m.store(NET_BASE + NET_R_DST_CAP_WORDS, 8, ram[0..]);
    m.store(NET_BASE + NET_R_DOORBELL, 1, ram[0..]);
    try expectEqual(@as(u32, NET_ST_READY), m.load(NET_BASE + NET_R_STATUS));
    try expectEqual(@as(u32, 2), m.load(NET_BASE + NET_R_COUNT));
}

test "G-NET-3: неизвестный топик — ERROR" {
    var m = Mmio{ .net_backend = goldenBackend };
    var ram = [_]u8{0} ** (MEMORY_SIZE_WORDS * 4);
    m.store(NET_BASE + NET_R_TOPIC, 99, ram[0..]);
    m.store(NET_BASE + NET_R_DST_WORD, 1000, ram[0..]);
    m.store(NET_BASE + NET_R_DST_CAP_WORDS, 12, ram[0..]);
    m.store(NET_BASE + NET_R_DOORBELL, 1, ram[0..]);
    try expectEqual(@as(u32, NET_ST_ERROR), m.load(NET_BASE + NET_R_STATUS));
    try expectEqual(@as(u32, 0), m.load(NET_BASE + NET_R_COUNT));
}

test "N4: буфер, залезающий в MMIO — ERROR" {
    var m = Mmio{ .net_backend = goldenBackend };
    var ram = [_]u8{0} ** (MEMORY_SIZE_WORDS * 4);
    m.store(NET_BASE + NET_R_TOPIC, TOPIC_QUAKES, ram[0..]);
    m.store(NET_BASE + NET_R_DST_WORD, MMIO_BASE_WORD - 4, ram[0..]);
    m.store(NET_BASE + NET_R_DST_CAP_WORDS, 8, ram[0..]);
    m.store(NET_BASE + NET_R_DOORBELL, 1, ram[0..]);
    try expectEqual(@as(u32, NET_ST_ERROR), m.load(NET_BASE + NET_R_STATUS));
}

test "G-DISP-1: CLEAR + POINT + COMMIT — кадр из 2 команд" {
    var m = Mmio{};
    var ram = [_]u8{0} ** 16;
    m.guestPushCmd(.{ .op = OP_CLEAR, .layer = 0, .color = 0, .size = 0, .x = 0, .y = 0 }, ram[0..]);
    m.guestPushCmd(.{ .op = OP_POINT, .layer = 0, .color = 6, .size = 5, .x = 729, .y = 364 }, ram[0..]);
    m.store(DISP_REG_BASE + DISP_R_CTRL, DISP_CTRL_COMMIT, ram[0..]);
    try expectEqual(@as(u32, 1), m.load(DISP_REG_BASE + DISP_R_FRAME_ID));
    try expectEqual(@as(u32, 4), m.load(DISP_REG_BASE + DISP_R_HEAD));
    const f = m.takeFrame().?;
    try expectEqual(@as(u32, 2), f.count);
    try expectEqual(OP_POINT, f.cmds[1].op);
    try expectEqual(@as(u8, 6), f.cmds[1].color);
    try expectEqual(@as(i16, 729), f.cmds[1].x);
    try expectEqual(@as(?*const Frame, null), m.takeFrame());
}

test "G-DISP-2: без COMMIT кадров нет" {
    var m = Mmio{};
    var ram = [_]u8{0} ** 16;
    m.guestPushCmd(.{ .op = OP_POINT, .layer = 1, .color = 8, .size = 3, .x = 1, .y = 2 }, ram[0..]);
    try expectEqual(@as(u32, 0), m.load(DISP_REG_BASE + DISP_R_FRAME_ID));
    try expectEqual(@as(?*const Frame, null), m.takeFrame());
}

test "D3/D4: мусорные команды игнорируются" {
    var m = Mmio{};
    var ram = [_]u8{0} ** 16;
    m.guestPushCmd(.{ .op = 200, .layer = 0, .color = 0, .size = 0, .x = 0, .y = 0 }, ram[0..]);
    m.guestPushCmd(.{ .op = OP_POINT, .layer = 30, .color = 6, .size = 1, .x = 0, .y = 0 }, ram[0..]);
    m.guestPushCmd(.{ .op = OP_POINT, .layer = 0, .color = 6, .size = 1, .x = 5, .y = 5 }, ram[0..]);
    m.store(DISP_REG_BASE + DISP_R_CTRL, DISP_CTRL_COMMIT, ram[0..]);
    const f = m.takeFrame().?;
    try expectEqual(@as(u32, 1), f.count);
    try expectEqual(@as(i16, 5), f.cmds[0].x);
}
