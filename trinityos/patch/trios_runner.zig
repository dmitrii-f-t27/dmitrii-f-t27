// SPDX-License-Identifier: Apache-2.0
// TrinityOS runner: TRI-27 + MMIO-устройства Ring 0.5.
// Ассемблирует .tasm, исполняет на настоящем CPU (executor.zig) с подключёнными
// устройствами CLK/INP/NET/DISP (trios_mmio.zig) и пишет защёлкнутые кадры в JSON.
//
// NET-бэкенды: golden (детерминированный датасет для тестов) или live —
// файл live_records.txt, который готовит мост workbench/fetch_live.py
// (реальные USGS/OpenSky/CelesTrak; движение смоделировано по шагам).
//
// Запуск: zig run trios_runner.zig -- program.tasm frames.json [live_records.txt] [unix]
// φ² + 1/φ² = 3 | TRINITY

const std = @import("std");
const tri_asm = @import("tri_asm.zig");
const executor = @import("executor.zig");
const cpu_mod = @import("cpu_state.zig");
const mmio = @import("trios_mmio.zig");

const STEP_SECONDS: u64 = 120; // шаг таймлапса между кадрами (как у моста)

var json_buf: [4 * 1024 * 1024]u8 = undefined;
var json_len: usize = 0;
var frame_count: u32 = 0;

fn jprint(comptime fmt: []const u8, args: anytype) void {
    const chunk = std.fmt.bufPrint(json_buf[json_len..], fmt, args) catch @panic("json_buf overflow");
    json_len += chunk.len;
}

fn onFrame(ctx: ?*anyopaque, f: *const mmio.Frame) void {
    const m: *mmio.Mmio = @ptrCast(@alignCast(ctx.?));
    if (frame_count != 0) jprint(",", .{});
    frame_count += 1;
    jprint("{{\"frame\":{d},\"mask\":{d},\"cmds\":[", .{ f.frame_id, f.layer_mask });
    var i: u32 = 0;
    while (i < f.count) : (i += 1) {
        const c = f.cmds[i];
        if (i != 0) jprint(",", .{});
        jprint("[{d},{d},{d},{d},{d},{d}]", .{ c.op, c.layer, c.color, c.size, c.x, c.y });
    }
    jprint("]}}", .{});
    // носитель тикает между кадрами в темпе таймлапса моста
    m.uptime_ms += STEP_SECONDS * 1000;
    m.unix_seconds += STEP_SECONDS;
}

fn hookLoad(ctx: *anyopaque, word_addr: u32) u32 {
    const m: *mmio.Mmio = @ptrCast(@alignCast(ctx));
    return m.load(word_addr);
}

fn hookStore(ctx: *anyopaque, word_addr: u32, value: u32, ram: []u8) void {
    const m: *mmio.Mmio = @ptrCast(@alignCast(ctx));
    m.store(word_addr, value, ram);
}

// ---- live-бэкенд: записи моста из файла ------------------------------------

const MAX_RECS = 128;
const MAX_STEPS = 16;

const Blocks = struct {
    n: [MAX_STEPS]u32 = @splat(0),
    steps: u32 = 0,
    recs: [MAX_STEPS][MAX_RECS]mmio.Rec4 = undefined,
};

var live_quakes = Blocks{};
var live_planes = Blocks{};
var live_sats = Blocks{};
var live_loaded = false;

fn blocksFor(topic: u32) ?*Blocks {
    return switch (topic) {
        mmio.TOPIC_QUAKES => &live_quakes,
        mmio.TOPIC_ADSB_XY => &live_planes,
        mmio.TOPIC_SATS_XY => &live_sats,
        else => null,
    };
}

fn loadLive(path: []const u8) !void {
    const src = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 16 * 1024 * 1024);
    var cur: ?*Blocks = null;
    var cur_step: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeScalar(u8, line, ' ');
        const first = toks.next() orelse continue;
        if (std.mem.eql(u8, first, "BLOCK")) {
            const topic = try std.fmt.parseInt(u32, toks.next().?, 10);
            cur_step = try std.fmt.parseInt(u32, toks.next().?, 10);
            cur = blocksFor(topic);
            if (cur) |b| {
                if (cur_step >= MAX_STEPS) {
                    cur = null;
                } else if (cur_step + 1 > b.steps) b.steps = cur_step + 1;
            }
            continue;
        }
        const b = cur orelse continue;
        if (b.n[cur_step] >= MAX_RECS) continue;
        var rec: mmio.Rec4 = undefined;
        rec[0] = try std.fmt.parseInt(u32, first, 10);
        inline for (1..4) |w| rec[w] = try std.fmt.parseInt(u32, toks.next().?, 10);
        b.recs[cur_step][b.n[cur_step]] = rec;
        b.n[cur_step] += 1;
    }
    live_loaded = true;
}

fn liveBackend(topic: u32, params: [4]u32, seq: u32, out: []mmio.Rec4) ?u32 {
    _ = seq;
    const b = blocksFor(topic) orelse return null;
    if (b.steps == 0) return null;
    // для пошаговых топиков шаг задаёт гость (PARAM1); лишнее зажимается
    const step: u32 = @min(params[1], b.steps - 1);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < b.n[step] and n < out.len) : (i += 1) {
        const rec = b.recs[step][i];
        if (topic == mmio.TOPIC_QUAKES and (rec[2] & 0xFFFF) < params[0]) continue;
        out[n] = rec;
        n += 1;
    }
    return n;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("usage: trios_runner program.tasm frames.json [live_records.txt] [unix]\n", .{});
        return;
    }

    const source = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
    const bytecode = try tri_asm.assemble(allocator, source);
    defer allocator.free(bytecode);

    var cpu = try cpu_mod.CPUState.init(allocator);
    defer cpu.deinit();
    const mem = cpu.getBytesMut();
    if (bytecode.len > mem.len) return error.ProgramTooLarge;
    @memcpy(mem[0..bytecode.len], bytecode);

    var m = mmio.Mmio{
        .net_backend = mmio.goldenBackend,
        .unix_seconds = 1_787_562_715,
    };
    if (args.len > 3) {
        try loadLive(args[3]);
        m.net_backend = liveBackend;
    }
    if (args.len > 4) m.unix_seconds = try std.fmt.parseInt(u64, args[4], 10);
    m.on_frame = onFrame;
    m.on_frame_ctx = &m;
    executor.mmio_hooks = .{ .ctx = &m, .load = hookLoad, .store = hookStore };

    jprint("[", .{});
    try executor.run(&cpu, mem);
    jprint("]", .{});

    const file = try std.fs.cwd().createFile(args[2], .{});
    defer file.close();
    try file.writeAll(json_buf[0..json_len]);

    std.debug.print(
        "TRI-27 halted: program {d} bytes, {d} instructions executed, {d} frames, net_seq {d}, backend {s}\n",
        .{ bytecode.len, cpu.instructions_executed, frame_count, m.net_seq, if (live_loaded) "live" else "golden" },
    );
}
