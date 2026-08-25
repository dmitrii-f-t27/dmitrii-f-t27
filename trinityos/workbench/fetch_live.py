# SPDX-License-Identifier: Apache-2.0
# Живой NET-мост Workbench: USGS + OpenSky + CelesTrak → записи устройства NET.
#
# Мост делает всё «внешнее» (TLS, JSON, SGP4, дедрекон) и выкладывает
# детерминированный файл live_records.txt: блоки записей по 4 слова,
# как их отдаст MMIO-устройство (спека specs/os/dev_net.t27).
# Движение по кадрам смоделировано мостом: шаг = STEP_SECONDS.
#
# python3 fetch_live.py  →  live_records.txt, live_meta.json
# φ² + 1/φ² = 3 | TRINITY

import json
import math
import os
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

STEPS = 9           # кадров живой анимации
STEP_SECONDS = 120  # шаг времени между кадрами (таймлапс)
MAX_QUAKES = 40
MAX_PLANES = 84
MAX_SATS = 60

TOPIC_QUAKES, TOPIC_ADSB_XY, TOPIC_SATS_XY = 1, 4, 5

USGS = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"
OPENSKY = "https://opensky-network.org/api/states/all"
CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle"


def fetch(url, tries=3):
    last = None
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=40) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 — ретраим любую сетевую ошибку
            last = e
            time.sleep(5 * (i + 1))
    raise SystemExit(f"мост не смог получить {url}: {last}")


def project(lat, lon):
    x = int((lon + 180.0) / 360.0 * 1458.0)
    y = int((90.0 - lat) / 180.0 * 729.0)
    return max(0, min(1457, x)), max(0, min(728, y))


def u32(v):
    return v & 0xFFFFFFFF


def xy_word(lat, lon):
    x, y = project(lat, lon)
    return u32(x | y << 16)


# --- USGS: землетрясения за сутки, M2.5+ -------------------------------------
def get_quakes(now):
    gj = json.loads(fetch(USGS))
    feats = sorted(gj["features"], key=lambda f: -(f["properties"]["mag"] or 0))
    recs = []
    for f in feats[:MAX_QUAKES]:
        lon, lat, depth = f["geometry"]["coordinates"]
        p = f["properties"]
        age_min = max(0, min(65535, int((now * 1000 - p["time"]) / 60000)))
        recs.append((
            u32(int(lat * 1e4)),
            u32(int(lon * 1e4)),
            u32(int(p["mag"] * 10) | max(0, int(depth)) << 16),
            u32(age_min),
        ))
    return recs, len(gj["features"])


# --- OpenSky: борта, дедрекон по курсу/скорости ------------------------------
def get_planes():
    data = json.loads(fetch(OPENSKY))
    alive = []
    for s in data.get("states") or []:
        lon, lat, vel, trk = s[5], s[6], s[9], s[10]
        if None in (lon, lat, vel, trk) or s[8]:  # s[8] = on_ground
            continue
        alt = s[13] or s[7] or 0
        if alt < 2000:
            continue
        alive.append((lat, lon, vel, trk, s[0]))
    step_n = max(1, len(alive) // MAX_PLANES)
    picked = alive[::step_n][:MAX_PLANES]

    steps = []
    for k in range(STEPS):
        dt = k * STEP_SECONDS
        recs = []
        for lat, lon, vel, trk, icao in picked:
            tr = math.radians(trk)
            dlat = vel * math.cos(tr) * dt / 111320.0
            coslat = max(0.1, math.cos(math.radians(lat)))
            dlon = vel * math.sin(tr) * dt / (111320.0 * coslat)
            la, lo = lat + dlat, ((lon + dlon + 180) % 360) - 180
            recs.append((xy_word(la, lo), u32(int(icao, 16)), 0, 0))
        steps.append(recs)
    return steps, len(alive), len(data.get("states") or [])


# --- CelesTrak: видимые спутники, SGP4-пропагация ----------------------------
def gmst(jd):
    t = (jd - 2451545.0) / 36525.0
    g = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t
    return math.radians((g % 86400) / 240.0)


def get_sats(now):
    from sgp4.api import Satrec, jday

    tle = fetch(CELESTRAK).decode().strip().splitlines()
    sats = []
    for i in range(0, len(tle) - 2, 3):
        name, l1, l2 = tle[i].strip(), tle[i + 1], tle[i + 2]
        try:
            sats.append((name, Satrec.twoline2rv(l1, l2)))
        except Exception:  # noqa: BLE001 — битую TLE пропускаем
            continue

    tt = time.gmtime(now)
    steps = [[] for _ in range(STEPS)]
    for name, sat in sats:
        if len(steps[0]) >= MAX_SATS:
            break
        ok = True
        pts = []
        for k in range(STEPS):
            jd, fr = jday(tt.tm_year, tt.tm_mon, tt.tm_mday,
                          tt.tm_hour, tt.tm_min, tt.tm_sec + k * STEP_SECONDS)
            e, r, _ = sat.sgp4(jd, fr)
            if e != 0:
                ok = False
                break
            lon = math.degrees(math.atan2(r[1], r[0]) - gmst(jd + fr))
            lon = ((lon + 180) % 360) - 180
            lat = math.degrees(math.atan2(r[2], math.hypot(r[0], r[1])))
            pts.append((lat, lon))
        if not ok:
            continue
        h = 0
        for ch in name:
            h = (h * 31 + ord(ch)) & 0xFFFFFFFF
        for k, (lat, lon) in enumerate(pts):
            steps[k].append((xy_word(lat, lon), h, 0, 0))
    return steps, len(sats)


def main():
    now = time.time()
    quakes, quakes_total = get_quakes(now)
    planes_steps, planes_alive, planes_total = get_planes()
    sats_steps, sats_total = get_sats(now)

    out = []
    out.append(f"BLOCK {TOPIC_QUAKES} 0 {len(quakes)}")
    out += [" ".join(map(str, r)) for r in quakes]
    for k, recs in enumerate(planes_steps):
        out.append(f"BLOCK {TOPIC_ADSB_XY} {k} {len(recs)}")
        out += [" ".join(map(str, r)) for r in recs]
    for k, recs in enumerate(sats_steps):
        out.append(f"BLOCK {TOPIC_SATS_XY} {k} {len(recs)}")
        out += [" ".join(map(str, r)) for r in recs]
    open(os.path.join(HERE, "live_records.txt"), "w").write("\n".join(out) + "\n")

    meta = {
        "fetched_at": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(now)),
        "unix": int(now),
        "quakes": len(quakes), "quakes_24h_total": quakes_total,
        "planes": len(planes_steps[0]), "planes_airborne_total": planes_alive,
        "planes_feed_total": planes_total,
        "sats": len(sats_steps[0]), "sats_catalog": sats_total,
        "steps": STEPS, "step_seconds": STEP_SECONDS,
        "sources": ["USGS 2.5_day", "OpenSky states/all", "CelesTrak visual TLE"],
    }
    json.dump(meta, open(os.path.join(HERE, "live_meta.json"), "w"),
              ensure_ascii=False, indent=1)
    print(json.dumps(meta, ensure_ascii=False))


if __name__ == "__main__":
    main()
