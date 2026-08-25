// SPDX-License-Identifier: Apache-2.0
// TrinityOS runner: TRI-27 + MMIO-устройства Ring 0.5.
// Ассемблирует .tasm, исполняет на настоящем CPU (executor.zig) с подключёнными
// устройствами CLK/INP/NET/DISP (trios_mmio.zig) и пишет защёлкнутые кадры в JSON.
//
// Запуск: zig run trios_runner.zig -- program.tasm frames.json
// φ² + 1/φ² = 3 | TRINITY

const std = @import("std");
const tri_asm = @import("tri_asm.zig");
const executor = @import("executor.zig");
const cpu_mod = @import("cpu_state.zig");
const mmio = @import("trios_mmio.zig");

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
    m.uptime_ms += 500; // носитель тикает между кадрами
}

fn hookLoad(ctx: *anyopaque, word_addr: u32) u32 {
    const m: *mmio.Mmio = @ptrCast(@alignCast(ctx));
    return m.load(word_addr);
}

fn hookStore(ctx: *anyopaque, word_addr: u32, value: u32, ram: []u8) void {
    const m: *mmio.Mmio = @ptrCast(@alignCast(ctx));
    m.store(word_addr, value, ram);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("usage: trios_runner program.tasm frames.json\n", .{});
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
        "TRI-27 halted: program {d} bytes, {d} instructions executed, {d} frames, net_seq {d}\n",
        .{ bytecode.len, cpu.instructions_executed, frame_count, m.net_seq },
    );
}
