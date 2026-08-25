# SPDX-License-Identifier: Apache-2.0
# Кодогенератор ROM «worldmap» для TrinityOS.
#
# Эмитит настоящую программу TRI-27 (.tasm): карта мира рисуется только
# инструкциями LDI/SHL/OR/LD/ST/ADD/SUB/MUL/DIV поверх MMIO-устройств
# из trinityos/specs/os/*.t27. Никакого кода на стороне носителя —
# растёт только дисплей-лист, который защёлкивает DISP.
#
# python3 gen_worldmap_tasm.py  →  worldmap.tasm
# φ² + 1/φ² = 3 | TRINITY

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# --- адреса из specs/os/mmio_map.t27 (в словах) ------------------------------
MMIO = 13122  # 2*3^8, ADR-M1: в досягаемости 15-битного immediate LD/ST
CLK_UPTIME_LO = MMIO + 2
NET = MMIO + 486
NET_DOORBELL, NET_STATUS, NET_TOPIC, NET_P0 = NET, NET + 1, NET + 2, NET + 3
NET_DST, NET_CAP, NET_COUNT = NET + 7, NET + 8, NET + 9
DISP = MMIO + 729
DISP_CTRL, DISP_TAIL = DISP, DISP + 3
RING = MMIO + 972
RING_WORDS = 1215

# --- ОЗУ гостя ---------------------------------------------------------------
QUAKES_DST = 6000   # байт 24000 — за концом программы (проверяется ниже)
ADSB_DST = 6100
QCOUNT_SAVE = 6090  # слово ОЗУ: COUNT квейков, сохранённый до adsb-запроса

# --- слои и цвета (палитра: индекс = 3 трита r,g,b) --------------------------
L_GRID, L_COAST, L_QUAKE, L_ADSB, L_TITLE, L_HUD = 0, 3, 9, 18, 25, 26
C_GRID, C_COAST, C_QUAKE, C_ADSB, C_TITLE, C_HUD = 13, 6, 18, 8, 6, 24

OP_CLEAR, OP_POINT, OP_MOVE, OP_LINE, OP_GLYPH = 1, 2, 3, 4, 5

lines = []
tail = 0
cmds_in_commit = 0


def emit(s):
    if s.startswith("LDI"):
        imm = int(s.split(",")[1])
        assert -16384 <= imm <= 16383, f"LDI вне 15-битного immediate: {s}"
    lines.append(s)


def lon_x(lon_e4):
    return (lon_e4 + 1800000) * 1458 // 3600000


def lat_y(lat_e4):
    return (900000 - lat_e4) * 729 // 1800000


def load_w0(reg, op, layer, color, size):
    """Собрать слово команды в регистре: op|layer<<8|color<<16|size<<24."""
    lo, hi = op | layer << 8, color | size << 8
    assert 0 <= lo <= 32767 and 0 <= hi <= 32767
    if hi == 0:
        emit(f"LDI {reg}, {lo}")
        return
    emit(f"LDI {reg}, {hi}")
    emit(f"SHL {reg}, {reg}, 16")
    emit("LDI t1, %d" % lo)
    emit(f"ADD {reg}, {reg}, t1")


def st_ring(w0reg, w1reg):
    """Записать команду (2 слова) в кольцо DISP."""
    global tail, cmds_in_commit
    emit(f"ST {w0reg}, {RING + tail}")
    emit(f"ST {w1reg}, {RING + (tail + 1) % RING_WORDS}")
    tail = (tail + 2) % RING_WORDS
    cmds_in_commit += 1


def cmd_xy(w0reg, x, y):
    """Команда с константными координатами: w1 = x | y<<16 в t1."""
    assert 0 <= x < 32768 and 0 <= y < 32768
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


def net_request(topic, p0, dst, cap):
    for val, addr in ((topic, NET_TOPIC), (p0, NET_P0), (dst, NET_DST),
                      (cap, NET_CAP), (1, NET_DOORBELL)):
        emit(f"LDI t3, {val}")
        emit(f"ST t3, {addr}")


def project_rec(base_word):
    """lat/lon записи NET → t1 = x|y<<16 (арифметика TRI-27, константы в t20-t24)."""
    emit(f"LD t2, {base_word + 1}")   # lon_e4
    emit("ADD t2, t2, t20")           # + 1800000
    emit("MUL t2, t2, t22")           # * 1458
    emit("DIV t2, t2, t21")           # / 3600000 → x
    emit(f"LD t3, {base_word}")       # lat_e4
    emit("SUB t3, t23, t3")           # 900000 - lat
    emit("MUL t3, t3, t24")           # * 729
    emit("DIV t3, t3, t20")           # / 1800000 → y
    emit("SHL t3, t3, 16")
    emit("ADD t1, t3, t2")


def glyph(ch, x, y, color, layer):
    """Статичный глиф: w0 = lo16 + (color + code<<8) << 16."""
    lo = OP_GLYPH | layer << 8
    emit(f"LDI t4, {ord(ch)}")
    emit("SHL t4, t4, 8")
    emit(f"LDI t3, {color}")
    emit("ADD t4, t4, t3")
    emit("SHL t4, t4, 16")
    emit(f"LDI t3, {lo}")
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


def count_glyph(count_addr, x, y):
    """Динамическая цифра: код = '0' + значение регистра устройства."""
    emit(f"LD t5, {count_addr}")
    emit("LDI t3, 48")
    emit("ADD t5, t5, t3")            # код символа
    emit("SHL t5, t5, 8")
    emit(f"LDI t3, {C_HUD}")
    emit("ADD t5, t5, t3")             # hi16 = color | code<<8
    emit("SHL t5, t5, 16")
    emit(f"LDI t3, {OP_GLYPH | L_HUD << 8}")
    emit("ADD t5, t5, t3")
    emit(f"LDI t3, {y}")
    emit("SHL t3, t3, 16")
    emit(f"LDI t2, {x}")
    emit("ADD t1, t3, t2")
    st_ring("t5", "t1")


# ============================================================================
emit("; TrinityOS ROM: worldmap — сгенерировано gen_worldmap_tasm.py")
emit("; Исполняется настоящим TRI-27 (executor.zig) с MMIO-устройствами")

# Константы проекции (equirectangular 1458x729).
# 1800000 собирается по половинам слова; 3600000 и 900000 у которых нижние
# 16 бит не влезают в знаковый LDI — выводятся из него арифметикой.
emit("LDI t6, 1800")         # 1800000 = 1800 * 1000: обе константы в 15 бит
emit("LDI t1, 1000")
emit("MUL t6, t6, t1")
emit("MOV t20, t6")
emit("ADD t21, t20, t20")   # 3600000
emit("LDI t3, 2")
emit("DIV t23, t20, t3")    # 900000
emit("LDI t22, 1458")
emit("LDI t24, 729")

# Кэшированные слова команд
load_w0("t10", OP_MOVE, L_GRID, C_GRID, 1)
load_w0("t11", OP_LINE, L_GRID, C_GRID, 1)
load_w0("t12", OP_MOVE, L_COAST, C_COAST, 1)
load_w0("t13", OP_LINE, L_COAST, C_COAST, 1)
load_w0("t14", OP_POINT, L_ADSB, C_ADSB, 4)
load_w0("t15", OP_POINT, L_QUAKE, C_QUAKE, 0)   # size добавится динамически
load_w0("t25", OP_CLEAR, L_ADSB, 0, 0)
load_w0("t26", OP_CLEAR, L_HUD, 0, 0)

# --- Кадр 1: сетка + береговая линия + заголовок -----------------------------
for lon in range(-180, 181, 30):
    x = lon_x(lon * 10000)
    cmd_xy("t10", x, 0)
    cmd_xy("t11", x, 728)
for lat in range(-90, 91, 30):
    y = lat_y(lat * 10000)
    cmd_xy("t10", 0, y)
    cmd_xy("t11", 1457, y)

coast = json.load(open(os.path.join(HERE, "coastline.json")))
for poly in coast:
    px, py = poly[0]
    cmd_xy("t12", px, py)
    for x, y in poly[1:]:
        # разрыв на антимеридиане: скачок долготы длиннее полукарты — не линия
        cmd_xy("t13" if abs(x - px) <= 729 else "t12", x, y)
        px, py = x, y

text("TRINITY OS // TRI-27 ROM", 12, 24, C_TITLE, L_TITLE)
commit()

# --- Кадр 2: землетрясения + первые борта + счётчики -------------------------
net_request(1, 50, QUAKES_DST, 16)          # QUAKES: mag >= 5.0
emit(f"LD t5, {NET_COUNT}")                 # COUNT квейков — сохранить до adsb
emit(f"ST t5, {QCOUNT_SAVE}")
for i in range(3):                          # датасет golden-3 детерминирован
    base = QUAKES_DST + i * 4
    project_rec(base)
    emit("MOV t6, t1")                      # w1 в t6, пока считаем размер
    emit(f"LD t4, {base + 2}")              # w2 = mag_x10 | depth<<16
    emit("LDI t3, 1")
    emit("SHL t3, t3, 16")                  # t3 = 65536 (LDI не берёт)
    emit("DIV t5, t4, t3")
    emit("MUL t5, t5, t3")
    emit("SUB t4, t4, t5")                  # mag_x10 = w2 mod 65536
    emit("LDI t3, 10")
    emit("DIV t4, t4, t3")
    emit("LDI t3, 2")
    emit("ADD t4, t4, t3")                  # size = 2 + mag
    emit("SHL t4, t4, 24")
    emit("ADD t4, t15, t4")                  # w0 quake
    st_ring("t4", "t6")


def draw_planes():
    net_request(2, 0, ADSB_DST, 20)
    st_ring("t25", "t25")                   # CLEAR слоя бортов (w1 игнорируется)
    for i in range(5):
        project_rec(ADSB_DST + i * 4)
        st_ring("t14", "t1")


def draw_hud(frame_no):
    st_ring("t26", "t26")                   # CLEAR слоя счётчиков
    text("Q:", 12, 52, C_HUD, L_HUD)
    count_glyph(QCOUNT_SAVE, 36, 52)        # из ОЗУ гостя (LD слова 6090)
    text("A:", 72, 52, C_HUD, L_HUD)
    count_glyph(NET_COUNT, 96, 52)          # прямо из регистра устройства
    text(f"F:{frame_no}", 132, 52, C_HUD, L_HUD)


draw_planes()
draw_hud(2)
commit()

# --- Кадры 3..8: дрейф бортов ------------------------------------------------
for frame_no in range(3, 9):
    draw_planes()
    draw_hud(frame_no)
    commit()

emit("HALT")

# ============================================================================
src = "\n".join(lines) + "\n"
n_instr = sum(1 for l in lines if l and not l.startswith(";"))
prog_bytes = 12 + n_instr * 4
assert prog_bytes < QUAKES_DST * 4, f"программа ({prog_bytes} б) наехала на NET-буфер"
out = os.path.join(HERE, "worldmap.tasm")
open(out, "w").write(src)
print(f"worldmap.tasm: {n_instr} инструкций, {prog_bytes} байт (лимит {QUAKES_DST * 4})")
