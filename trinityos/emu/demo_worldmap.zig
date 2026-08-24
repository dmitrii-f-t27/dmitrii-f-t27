// SPDX-License-Identifier: Apache-2.0
// TrinityOS M0 demo: «гость» рисует карту мира через устройства DISP/NET/CLK.
// Каждое действие здесь — то, что в настоящем TRI-27 будет парой LOAD/STORE;
// никакого доступа к экрану или сети мимо MMIO у гостя нет.
//
// Выход: build/frames.jsonl (кадры для CI) и observer/frames.js (для обсервера).
// Запуск: zig run emu/demo_worldmap.zig
// φ² + 1/φ² = 3 | TRINITY

const std = @import("std");
const mmio = @import("mmio.zig");

var ram: [mmio.MEMORY_SIZE_WORDS * 4]u8 = undefined;
var json_buf: [2 * 1024 * 1024]u8 = undefined;
var json_len: usize = 0;

const FRAMES = 9;
const L_GRID: u8 = 0; // сетка-градусник
const L_QUAKE: u8 = 9; // землетрясения
const L_ADSB: u8 = 18; // борта
const L_HUD: u8 = 26; // текст HUD

const C_GRID: u8 = 13; // серый
const C_QUAKE: u8 = 18; // красный
const C_ADSB: u8 = 8; // циан
const C_HUD: u8 = 6; // зелёный

fn jprint(comptime fmt: []const u8, args: anytype) void {
    const chunk = std.fmt.bufPrint(json_buf[json_len..], fmt, args) catch @panic("json_buf overflow");
    json_len += chunk.len;
}

fn lonToX(lon_e4: i32) i16 {
    const x = @divTrunc((@as(i64, lon_e4) + 1_800_000) * mmio.VIRT_W, 3_600_000);
    return @intCast(std.math.clamp(x, 0, mmio.VIRT_W - 1));
}

fn latToY(lat_e4: i32) i16 {
    const y = @divTrunc((900_000 - @as(i64, lat_e4)) * mmio.VIRT_H, 1_800_000);
    return @intCast(std.math.clamp(y, 0, mmio.VIRT_H - 1));
}

fn cmd(m: *mmio.Mmio, op: u8, layer: u8, color: u8, size: u8, x: i16, y: i16) void {
    m.guestPushCmd(.{ .op = op, .layer = layer, .color = color, .size = size, .x = x, .y = y }, ram[0..]);
}

fn drawText(m: *mmio.Mmio, layer: u8, color: u8, x: i16, y: i16, s: []const u8) void {
    for (s, 0..) |ch, i| {
        cmd(m, mmio.OP_GLYPH, layer, color, ch, x + @as(i16, @intCast(i)) * 12, y);
    }
}

fn drawGraticule(m: *mmio.Mmio) void {
    cmd(m, mmio.OP_CLEAR, L_GRID, 0, 0, 0, 0);
    var lon: i32 = -180;
    while (lon <= 180) : (lon += 30) {
        const x = lonToX(lon * 10_000);
        cmd(m, mmio.OP_MOVE_TO, L_GRID, C_GRID, 1, x, 0);
        cmd(m, mmio.OP_LINE_TO, L_GRID, C_GRID, 1, x, mmio.VIRT_H - 1);
    }
    var lat: i32 = -90;
    while (lat <= 90) : (lat += 30) {
        const y = latToY(lat * 10_000);
        cmd(m, mmio.OP_MOVE_TO, L_GRID, C_GRID, 1, 0, y);
        cmd(m, mmio.OP_LINE_TO, L_GRID, C_GRID, 1, mmio.VIRT_W - 1, y);
    }
}

/// NET-запрос как его делает гость: регистры → doorbell → чтение результата из ОЗУ
fn netFetch(m: *mmio.Mmio, topic: u32, p0: u32, dst_word: u32, cap_words: u32) u32 {
    m.store(mmio.NET_BASE + mmio.NET_R_TOPIC, topic, ram[0..]);
    m.store(mmio.NET_BASE + mmio.NET_R_PARAM0, p0, ram[0..]);
    m.store(mmio.NET_BASE + mmio.NET_R_DST_WORD, dst_word, ram[0..]);
    m.store(mmio.NET_BASE + mmio.NET_R_DST_CAP_WORDS, cap_words, ram[0..]);
    m.store(mmio.NET_BASE + mmio.NET_R_DOORBELL, 1, ram[0..]);
    if (m.load(mmio.NET_BASE + mmio.NET_R_STATUS) != mmio.NET_ST_READY) return 0;
    return m.load(mmio.NET_BASE + mmio.NET_R_COUNT);
}

fn ramWordI32(word_addr: u32) i32 {
    return std.mem.readInt(i32, ram[word_addr * 4 ..][0..4], .little);
}

fn ramWordU32(word_addr: u32) u32 {
    return std.mem.readInt(u32, ram[word_addr * 4 ..][0..4], .little);
}

fn emitFrame(f: *const mmio.Frame) void {
    jprint("{{\"frame\":{d},\"mask\":{d},\"cmds\":[", .{ f.frame_id, f.layer_mask });
    var i: u32 = 0;
    while (i < f.count) : (i += 1) {
        const c = f.cmds[i];
        if (i != 0) jprint(",", .{});
        jprint("[{d},{d},{d},{d},{d},{d}]", .{ c.op, c.layer, c.color, c.size, c.x, c.y });
    }
    jprint("]}}", .{});
}

pub fn main() !void {
    var m = mmio.Mmio{
        .net_backend = mmio.goldenBackend,
        .unix_seconds = 1_787_562_715,
    };
    @memset(ram[0..], 0);

    jprint("[", .{});
    var frame: u32 = 0;
    var quake_count: u32 = 0;
    while (frame < FRAMES) : (frame += 1) {
        if (frame == 0) {
            drawGraticule(&m);
            // Землетрясения статичны в датасете golden-3 — рисуем один раз
            quake_count = netFetch(&m, mmio.TOPIC_QUAKES, 50, 1000, 40);
            cmd(&m, mmio.OP_CLEAR, L_QUAKE, 0, 0, 0, 0);
            var q: u32 = 0;
            while (q < quake_count) : (q += 1) {
                const base = 1000 + q * 4;
                const mag_x10: u32 = ramWordU32(base + 2) & 0xFFFF;
                cmd(&m, mmio.OP_POINT, L_QUAKE, C_QUAKE, @intCast(2 + mag_x10 / 10), lonToX(ramWordI32(base + 1)), latToY(ramWordI32(base)));
            }
        }

        // Борта — каждый кадр заново (дрейф детерминирован seq моста)
        const adsb_count = netFetch(&m, mmio.TOPIC_ADSB, 0, 2000, 40);
        cmd(&m, mmio.OP_CLEAR, L_ADSB, 0, 0, 0, 0);
        var a: u32 = 0;
        while (a < adsb_count) : (a += 1) {
            const base = 2000 + a * 4;
            cmd(&m, mmio.OP_POINT, L_ADSB, C_ADSB, 4, lonToX(ramWordI32(base + 1)), latToY(ramWordI32(base)));
        }

        // HUD с живыми счётчиками
        cmd(&m, mmio.OP_CLEAR, L_HUD, 0, 0, 0, 0);
        var hud: [64]u8 = undefined;
        const uptime = m.load(mmio.CLK_BASE + mmio.CLK_R_UPTIME_MS_LO);
        const text = std.fmt.bufPrint(hud[0..], "TRINITY OS M0  Q:{d} A:{d} T:{d}", .{ quake_count, adsb_count, uptime }) catch unreachable;
        drawText(&m, L_HUD, C_HUD, 12, 24, text);

        // COMMIT и сбор кадра носителем
        m.store(mmio.DISP_REG_BASE + mmio.DISP_R_CTRL, mmio.DISP_CTRL_COMMIT, ram[0..]);
        const f = m.takeFrame() orelse @panic("frame expected");
        if (frame != 0) jprint(",", .{});
        emitFrame(f);
        m.uptime_ms += 500; // носитель тикает между кадрами
    }
    jprint("]", .{});

    // build/frames.jsonl — по кадру на строку (для дифф-голденов CI)
    try std.fs.cwd().makePath("build");
    {
        const file = try std.fs.cwd().createFile("build/frames.json", .{});
        defer file.close();
        try file.writeAll(json_buf[0..json_len]);
    }
    // observer/frames.js — то же самое как данные для обсервера
    {
        const file = try std.fs.cwd().createFile("observer/frames.js", .{});
        defer file.close();
        try file.writeAll("window.TRINITY_FRAMES = ");
        try file.writeAll(json_buf[0..json_len]);
        try file.writeAll(";\n");
    }
    std.debug.print("ok: {d} frames, {d} bytes json\n", .{ FRAMES, json_len });
}
