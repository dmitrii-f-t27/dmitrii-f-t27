# God's Eye View (WorldView) — данные для запуска у себя

Разбор видео **[«Ex-Google Maps PM Vibe Coded Palantir In a Weekend»](https://youtu.be/rXvU7bPJ8n4)** (Bilawal Sidhu, ex-PM Google Maps).
Проект: спутниковый «шпионский» симулятор в браузере на фотореалистичном 3D-глобусе, все данные — публичные.

- Официальный репозиторий: <https://github.com/bilawalsidhu/gods-eye-view> — пока только README; **публичный релиз кода назначен на 24.08.2026** (следить за репо / рассылкой <https://spatialintelligence.ai/>).
- Авторский разбор: <https://www.spatialintelligence.ai/p/i-built-a-spy-satellite-simulator>
- Эпизод про Ормузский пролив (суда, кабели): <https://www.spatialintelligence.ai/p/one-chokepoint-controls-everything>

---

## 1. Источники данных (ядро проекта)

Все бесплатные эндпоинты проверены 24.08.2026 — работают.

| Слой | Источник | Эндпоинт | Ключ/цена |
|---|---|---|---|
| 3D-глобус (фотореалистичные города) | **Google Photorealistic 3D Tiles** (Map Tiles API) | `https://tile.googleapis.com/v1/3dtiles/root.json?key=KEY` | **Нужен API-ключ Google Cloud**; главный платный компонент (есть free tier) |
| Гражданская авиация (~7000 бортов live) | **OpenSky Network** | `https://opensky-network.org/api/states/all` | Бесплатно; аноним — жёсткие лимиты, лучше зарегистрировать OAuth2-клиента |
| Военная авиация (ADS-B) | **ADS-B Exchange** (в видео) | API через RapidAPI | Платно |
| — бесплатные аналоги (проверены) | adsb.fi / adsb.lol | `https://opendata.adsb.fi/api/v2/mil`, `https://api.adsb.lol/v2/mil` | Бесплатно, без ключа |
| Спутники (180+ орбит, TLE) | **CelesTrak** | `https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle` (в видео: `celestrak.org/pub/TLE/active.tle`) | Бесплатно; орбиты считать SGP4 (satellite.js) |
| Землетрясения (live) | **USGS** | `https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson` | Бесплатно |
| Уличные камеры (Остин, проекция на 3D) | **City of Austin open data** | список камер: `https://data.austintexas.gov/resource/b4k4-adkb.json`; снимки: `cctv.austinmobility.io` | Бесплатно |
| Дорожная сеть → частицы трафика | **OpenStreetMap** | Overpass API (выгрузка дорожного графа) | Бесплатно |

Дополнительные слои из серии God's Eye View (не все в этом видео):

- **Суда (AIS)** — в серии упоминается MarineTraffic (платно); бесплатная альтернатива — aisstream.io (WebSocket, нужен бесплатный ключ).
- **Подводные кабели** — открытые данные TeleGeography: <https://github.com/telegeography/www.submarinecablemap.com>.
- **GPS-глушение/интерференция** — производная от ADS-B (аналог gpsjam.org); фигурирует в эпизоде «Operation Epic Fury».

## 2. Технологический стек

- **CesiumJS** + WebGL (подтверждено топиками официального репозитория: cesium, webgl, photogrammetry) поверх Google 3D Tiles.
- **Next.js + React** — обвязка приложения (по анонсу открытого релиза).
- Кастомные **шейдеры-фильтры**: CRT scan lines, night vision (NVG), FLIR thermal, anime cel-shading, «God mode» с детекционными оверлеями.
- **Партикл-система** для трафика по дорогам OSM; **проективное текстурирование** CCTV-потоков на 3D-геометрию города.
- Всё работает в браузере; нужен нормальный GPU.

## 3. Как автор это построил (процесс «vibe coding»)

- Модели: **Gemini 3.1, Claude 4.6, Codex 5.3** — терминальные агенты, до **8 параллельно**, каждый на своей подсистеме (шейдеры, интеграции API и т.д.).
- ТЗ агентам — голосовые заметки и скриншоты, а не написанный вручную код.
- Ключевой приём против падений браузера: ступенчатая загрузка данных (сначала магистрали, потом мелкие улицы).
- Сроки: рабочий прототип за выходные, полный проект ~3 дня.

## 4. Чеклист для запуска у себя

1. Google Cloud: включить **Map Tiles API**, получить ключ (единственный обязательный платный ключ; поставить лимиты бюджета).
2. Зарегистрировать клиента **OpenSky** (бесплатно) для нормальных rate-limit'ов.
3. Военные борта: бесплатно adsb.fi / adsb.lol, либо подписка ADS-B Exchange.
4. CelesTrak, USGS, камеры Остина, OSM/Overpass — без регистрации.
5. Для судов — ключ **aisstream.io** (бесплатно); кабели — датасет TeleGeography.
6. Дождаться публикации кода в `bilawalsidhu/gods-eye-view` (обещан 24.08.2026) — иначе собирать самим на CesiumJS + Next.js по списку выше.
