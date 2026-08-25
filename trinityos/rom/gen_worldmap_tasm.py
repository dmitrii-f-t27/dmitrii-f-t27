# SPDX-License-Identifier: Apache-2.0
# Кодогенератор ROM «worldview» для TrinityOS (v2 — живые данные).
#
# Эмитит настоящую программу TRI-27 (.tasm): карта мира, живые землетрясения
# (USGS), борта (OpenSky) с трейлами, спутники (CelesTrak/SGP4) с орбитальными
# следами и UTC-часы, посчитанные арифметикой TRI-27 из регистра CLK.
# Данные приходят только через MMIO-устройство NET (мост workbench/fetch_live.py).
#
# ISA-ограничения учтены жёстко (см. README «Находки в ISA»):
#   * immediate 15 бит со знаком — страж на каждый LDI/LD/ST/JZ;
#   * SHL/SHR только на t0..t15 (4-битный src1);
#   * OR тернарный — битовые поля собираются ADD непересекающихся полей;
#   * косвенной адресации нет — все циклы развёрнуты по счётчикам из live_meta.
#
# python3 gen_worldmap_tasm.py  →  worldmap.tasm
# φ² + 1/φ² = 3 | TRINITY

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
META = json.load(open(os.path.join(HERE, "..", "workbench", "live_meta.json")))

# --- адреса из specs/os/mmio_map.t27 (в словах) ------------------------------
MMIO = 13122  # 2*3^8, ADR-M1
CLK_UNIX_LO = MMIO + 0
NET = MMIO + 486
NET_DOORBELL, NET_TOPIC, NET_P0, NET_P1 = NET, NET + 2, NET + 3, NET + 4
NET_DST, NET_CAP, NET_COUNT = NET + 7, NET + 8, NET + 9
DISP = MMIO + 729
DISP_CTRL, DISP_TAIL = DISP, DISP + 3
RING = MMIO + 972
RING_WORDS = 1215

TOPIC_QUAKES, TOPIC_ADSB_XY, TOPIC_SATS_XY = 1, 4, 5

# --- ОЗУ гостя: буферы NET выше окна MMIO (достижимы 15-битным immediate) ----
QUAKES_DST, QUAKES_CAP = 15400, 160
ADSB_DST, ADSB_CAP = 15600, 336
SATS_DST, SATS_CAP = 16000, 240
SAVE_Q, SAVE_A, SAVE_S = 16340, 16341, 16342

N_QUAKES = min(META["quakes"], QUAKES_CAP // 4)
N_PLANES = min(META["planes"], ADSB_CAP // 4)
N_SATS = min(META["sats"], SATS_CAP // 4)
LIVE_FRAMES = min(META["steps"], 7)

# --- слои и цвета (палитра: индекс = 3 трита r,g,b) --------------------------
L_GRID, L_COAST, L_QUAKE = 0, 3, 9
L_ADSB, L_ADSB_TRAIL, L_SAT, L_SAT_TRAIL = 18, 19, 21, 22
L_STATIC, L_DYN = 25, 26
C_GRID, C_COAST, C_QUAKE, C_ADSB, C_TRAIL = 13, 6, 18, 8, 4
C_SAT, C_SAT_TRAIL, C_TITLE, C_LABEL, C_DYN = 26, 13, 6, 13, 24

OP_CLEAR, OP_POINT, OP_MOVE, OP_LINE, OP_GLYPH = 1, 2, 3, 4, 5

lines = []
tail = 0
cmds_in_commit = 0


def emit(s):
    op = s.split()[0]
    if op in ("LDI", "LD", "ST", "JZ", "JNZ", "JMP", "SHL", "SHR"):
        imm = int(s.split(",")[-1]) if op != "JMP" else int(s.split()[-1])
        assert -16384 <= imm <= 16383, f"immediate вне 15 бит: {s}"
    if op in ("SHL", "SHR"):
        reg = int(s.split()[1].strip(",").lstrip("t"))
        assert reg <= 15, f"SHL/SHR src1 кодируется 4 битами: {s}"
    lines.append(s)


def lon_x(lon_e4):
    return (lon_e4 + 1800000) * 1458 // 3600000


def lat_y(lat_e4):
    return (900000 - lat_e4) * 729 // 1800000


def load_w0(reg, op, layer, color, size):
    """w0 = op|layer<<8|color<<16|size<<24 в регистре (reg <= t15 для SHL)."""
    lo, hi = op | layer << 8, color | size << 8
    assert 0 <= lo <= 16383 and 0 <= hi <= 16383
    if hi == 0:
        emit(f"LDI {reg}, {lo}")
        return
    emit(f"LDI {reg}, {hi}")
    emit(f"SHL {reg}, {reg}, 16")
    emit(f"LDI t1, {lo}")
    emit(f"ADD {reg}, {reg}, t1")


def st_ring(w0reg, w1reg):
    global tail, cmds_in_commit
    emit(f"ST {w0reg}, {RING + tail}")
    emit(f"ST {w1reg}, {RING + (tail + 1) % RING_WORDS}")
    tail = (tail + 2) % RING_WORDS
    cmds_in_commit += 1


def cmd_xy(w0reg, x, y):
    """Команда с константными координатами: w1 = x | y<<16 в t1."""
    emit(f"LDI t3, {y}")
    emit("SHL t3, t3, 16")
    emit(f"LDI t2, {x}")
    emit("ADD t1, t3, t2")
    st_ring(w0reg, "t1")


def commit():
    global cmds_in_commit
    assert cmds_in_commit <= 606, f"ring overflow: {cmds_in_commit}"
    emit(f"LDI t3, {tail}")
    emit(f"ST t3, {DISP_TAIL}")
    emit("LDI t3, 1")
    emit(f"ST t3, {DISP_CTRL}")
    cmds_in_commit = 0


def net_request(topic, p0, p1, dst, cap):
    for val, addr in ((topic, NET_TOPIC), (p0, NET_P0), (p1, NET_P1),
                      (dst, NET_DST), (cap, NET_CAP), (1, NET_DOORBELL)):
        emit(f"LDI t3, {val}")
        emit(f"ST t3, {addr}")


def glyph(ch, x, y, color, layer):
    """Статичный глиф: w0 собирается сдвигом кода символа (код не влезает <<8 в LDI)."""
    emit(f"LDI t4, {ord(ch)}")
    emit("SHL t4, t4, 8")
    emit(f"LDI t3, {color}")
    emit("ADD t4, t4, t3")
    emit("SHL t4, t4, 16")
    emit(f"LDI t3, {OP_GLYPH | layer << 8}")
    emit("ADD t4, t4, t3")
    emit(f"LDI t3, {y}")
    emit("SHL t3, t3, 16")
    emit(f"LDI t2, {x}")
    emit("ADD t1, t3, t2")
    st_ring("t4", "t1")


def text(s, x, y, color, layer):
    for i, ch in enumerate(s):
        if ch != " ":
            glyph(ch, x + i * 12, y, color, layer)


def digit_glyph(reg, x, y):
    """Глиф цифры 0..9 из регистра reg (t2..t6); клобберит t1, t3 и сам reg."""
    assert reg not in ("t1", "t3"), "t1/t3 — временные регистры глифа"
    emit("LDI t3, 48")
    emit(f"ADD {reg}, {reg}, t3")
    emit(f"SHL {reg}, {reg}, 8")
    emit(f"LDI t3, {C_DYN}")
    emit(f"ADD {reg}, {reg}, t3")
    emit(f"SHL {reg}, {reg}, 16")
    emit(f"LDI t3, {OP_GLYPH | L_DYN << 8}")
    emit(f"ADD {reg}, {reg}, t3")
    emit(f"LDI t3, {y}")
    emit("SHL t3, t3, 16")
    emit(f"LDI t1, {x}")
    emit("ADD t3, t3, t1")
    st_ring(reg, "t3")


def two_digit_counter(addr, x, y):
    """Двузначный счётчик из слова ОЗУ/регистра устройства: клобберит t2..t6."""
    emit(f"LD t5, {addr}")
    emit("LDI t6, 10")
    emit("DIV t4, t5, t6")        # старшая цифра
    emit("MUL t6, t4, t6")
    emit("SUB t5, t5, t6")        # младшая цифра
    digit_glyph("t4", x, y)
    digit_glyph("t5", x + 12, y)


# ============================================================================
emit(f"; TrinityOS ROM worldview v2 — {META['fetched_at']}")
emit(f"; live: {META['quakes']} quakes, {META['planes']}/{META['planes_airborne_total']} planes, {META['sats']} sats")

# Константы проекции (нужны для квейков — TRI-27 проецирует их сам)
emit("LDI t6, 1800")
emit("LDI t1, 1000")
emit("MUL t6, t6, t1")
emit("MOV t20, t6")           # 1800000
emit("ADD t21, t20, t20")     # 3600000
emit("LDI t3, 2")
emit("DIV t23, t20, t3")      # 900000
emit("LDI t22, 1458")
emit("LDI t24, 729")
emit("LDI t6, 864")
emit("LDI t1, 100")
emit("MUL t6, t6, t1")
emit("MOV t25, t6")           # 86400 (для UTC-часов)
emit("LDI t26, 3600")

# --- Кадр 1: сетка + береговая линия (часть A) -------------------------------
load_w0("t14", OP_MOVE, L_GRID, C_GRID, 1)
load_w0("t15", OP_LINE, L_GRID, C_GRID, 1)
for lon in range(-180, 181, 30):
    x = lon_x(lon * 10000)
    cmd_xy("t14", x, 0)
    cmd_xy("t15", x, 728)
for lat in range(-90, 91, 30):
    y = lat_y(lat * 10000)
    cmd_xy("t14", 0, y)
    cmd_xy("t15", 1457, y)

coast = json.load(open(os.path.join(HERE, "coastline.json")))
segs = []
for poly in coast:
    px, py = poly[0]
    segs.append(("m", px, py))
    for x, y in poly[1:]:
        segs.append(("l" if abs(x - px) <= 729 else "m", x, y))
        px, py = x, y

load_w0("t14", OP_MOVE, L_COAST, C_COAST, 1)
load_w0("t15", OP_LINE, L_COAST, C_COAST, 1)
half = len(segs) * 5 // 8
for kind, x, y in segs[:half]:
    cmd_xy("t14" if kind == "m" else "t15", x, y)
commit()

# --- Кадр 2: континенты (часть B) + подписи + живые землетрясения ------------
prev = segs[half - 1]
cmd_xy("t14", prev[1], prev[2])   # переустановить курсор после разрыва кадра
for kind, x, y in segs[half:]:
    cmd_xy("t14" if kind == "m" else "t15", x, y)

text("TRINITY OS // WORLDVIEW", 12, 24, C_TITLE, L_STATIC)
text("LIVE " + META["fetched_at"], 12, 706, C_LABEL, L_STATIC)
text("USGS / OPENSKY / CELESTRAK / TRI-27", 460, 706, C_LABEL, L_STATIC)
text("Q:", 12, 52, C_LABEL, L_STATIC)
text("A:", 100, 52, C_LABEL, L_STATIC)
text("S:", 190, 52, C_LABEL, L_STATIC)
text("F:", 244, 52, C_LABEL, L_STATIC)
text("UTC", 280, 52, C_LABEL, L_STATIC)
glyph(":", 354, 52, C_DYN, L_STATIC)

net_request(TOPIC_QUAKES, 0, 0, QUAKES_DST, QUAKES_CAP)
emit(f"LD t5, {NET_COUNT}")
emit(f"ST t5, {SAVE_Q}")
load_w0("t15", OP_POINT, L_QUAKE, C_QUAKE, 0)   # size добавится из магнитуды
for i in range(N_QUAKES):
    base = QUAKES_DST + i * 4
    emit(f"LD t2, {base + 1}")    # lon_e4
    emit("ADD t2, t2, t20")
    emit("MUL t2, t2, t22")
    emit("DIV t2, t2, t21")       # x
    emit(f"LD t3, {base}")        # lat_e4
    emit("SUB t3, t23, t3")
    emit("MUL t3, t3, t24")
    emit("DIV t3, t3, t20")       # y
    emit("SHL t3, t3, 16")
    emit("ADD t6, t3, t2")        # w1
    emit(f"LD t4, {base + 2}")    # w2 = mag_x10 | depth<<16
    emit("LDI t3, 1")
    emit("SHL t3, t3, 16")
    emit("DIV t5, t4, t3")
    emit("MUL t5, t5, t3")
    emit("SUB t4, t4, t5")        # mag_x10
    emit("LDI t3, 10")
    emit("DIV t4, t4, t3")
    emit("LDI t3, 2")
    emit("ADD t4, t4, t3")        # size = 2 + mag
    emit("SHL t4, t4, 24")
    emit("ADD t4, t15, t4")
    st_ring("t4", "t6")
commit()

# --- Кадры 3..: живые борта и спутники с трейлами, счётчики, UTC -------------
load_w0("t7", OP_POINT, L_ADSB, C_ADSB, 4)
load_w0("t8", OP_POINT, L_ADSB_TRAIL, C_TRAIL, 1)
load_w0("t9", OP_POINT, L_SAT, C_SAT, 3)
load_w0("t10", OP_POINT, L_SAT_TRAIL, C_SAT_TRAIL, 1)
load_w0("t11", OP_CLEAR, L_ADSB, 0, 0)
load_w0("t12", OP_CLEAR, L_SAT, 0, 0)
load_w0("t13", OP_CLEAR, L_DYN, 0, 0)

for step in range(LIVE_FRAMES):
    emit(f"; --- живой кадр, шаг таймлапса {step} ---")
    net_request(TOPIC_ADSB_XY, 0, step, ADSB_DST, ADSB_CAP)
    emit(f"LD t5, {NET_COUNT}")
    emit(f"ST t5, {SAVE_A}")
    net_request(TOPIC_SATS_XY, 0, step, SATS_DST, SATS_CAP)
    emit(f"LD t5, {NET_COUNT}")
    emit(f"ST t5, {SAVE_S}")

    st_ring("t11", "t11")             # CLEAR бортов (w1 игнорируется)
    st_ring("t12", "t12")             # CLEAR спутников
    st_ring("t13", "t13")             # CLEAR динамического HUD

    for i in range(N_PLANES):
        emit(f"LD t1, {ADSB_DST + i * 4}")   # w0 записи = x|y<<16
        st_ring("t8", "t1")                  # трейл (слой не чистится)
        st_ring("t7", "t1")                  # текущая позиция
    for i in range(N_SATS):
        emit(f"LD t1, {SATS_DST + i * 4}")
        st_ring("t10", "t1")                 # орбитальный след
        st_ring("t9", "t1")

    two_digit_counter(SAVE_Q, 36, 52)
    two_digit_counter(SAVE_A, 124, 52)
    two_digit_counter(SAVE_S, 214, 52)
    glyph(str(step + 3), 268, 52, C_DYN, L_DYN)   # номер кадра

    # UTC-часы: время суток из CLK, посчитанное самим TRI-27
    emit(f"LD t5, {CLK_UNIX_LO}")
    emit("DIV t4, t5, t25")
    emit("MUL t4, t4, t25")
    emit("SUB t5, t5, t4")        # секунды суток
    emit("DIV t4, t5, t26")       # часы
    emit("MUL t3, t4, t26")
    emit("SUB t5, t5, t3")
    emit("LDI t3, 60")
    emit("DIV t5, t5, t3")        # минуты
    emit("LDI t6, 10")
    emit("DIV t2, t4, t6")        # h десятки
    emit("MUL t3, t2, t6")
    emit("SUB t4, t4, t3")        # h единицы
    emit("MOV t6, t5")            # минуты — в t6, пока рисуем часы
    digit_glyph("t2", 330, 52)
    digit_glyph("t4", 342, 52)
    emit("LDI t3, 10")
    emit("DIV t2, t6, t3")        # m десятки
    emit("MUL t3, t2, t3")
    emit("SUB t6, t6, t3")        # m единицы
    digit_glyph("t2", 360, 52)
    digit_glyph("t6", 372, 52)
    commit()

emit("HALT")

# ============================================================================
src = "\n".join(lines) + "\n"
n_instr = sum(1 for l in lines if l and not l.startswith(";"))
prog_bytes = 12 + n_instr * 4
assert prog_bytes < MMIO * 4, f"программа ({prog_bytes} б) наехала на окно MMIO"
open(os.path.join(HERE, "worldmap.tasm"), "w").write(src)
print(f"worldmap.tasm: {n_instr} инструкций, {prog_bytes} байт (лимит {MMIO * 4}); "
      f"{N_QUAKES} квейков, {N_PLANES} бортов, {N_SATS} спутников, {LIVE_FRAMES} живых кадров")
