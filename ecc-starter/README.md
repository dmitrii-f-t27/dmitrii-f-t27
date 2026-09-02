# ECC Starter Kit для стека Trinity

Курируемая выборка из [affaan-m/ECC](https://github.com/affaan-m/ECC) (Everything Claude Code) —
только то, что нужно под наш стек, вместо всех 286 скиллов и 68 агентов.

- **Источник:** ECC v2.2.1, коммит `ca185ef` от 2026-08-31 (MIT, см. `LICENSE-ECC`)
- **Стек, под который сделана выборка:** Zig, Verilog/FPGA, Python, C (репозитории Trinity: trinity, trinity-fpga, t27, trinity-contracts)

## Состав (10 компонентов)

### Агенты (`agents/` → `~/.claude/agents/`)

| Агент | Зачем нам |
|---|---|
| `planner` | Планирование сложных фич до кода — универсальный |
| `code-reviewer` | Ревью качества после каждого изменения — универсальный |
| `security-reviewer` | Проверка перед коммитом; критично для trinity-contracts и C-кода |
| `build-error-resolver` | Чинит ошибки сборки; полезен и для build.zig |
| `cpp-reviewer` | Ревью C/C++ — ближайший к нашему C и low-level Zig-коду |
| `python-reviewer` | Ревью тренировочных скриптов (train_cifar10.py и т.п.) |

### Скиллы (`skills/` → `~/.claude/skills/`)

| Скилл | Зачем нам |
|---|---|
| `continuous-learning-v2` | Автоизвлечение «инстинктов» из сессий: агент учится на наших паттернах |
| `tdd-workflow` | Тест-до-кода процесс |
| `verification-loop` | Цикл верификации изменений перед сдачей |
| `latency-critical-systems` | Hot paths, p95, freshness — релевантно ternary-инференсу и стримингу |

### Правила (`rules/` → `~/.claude/rules/ecc/`)

- `common/` — базовые стандарты (security, testing, git-workflow, performance)
- `cpp/` — для C-кода
- `python/` — для Python-кода

В ECC нет паков для Zig и Verilog — если понадобятся, пишем свои по образцу `cpp/`.

## Установка

На своей машине:

```bash
git clone https://github.com/dmitrii-f-t27/dmitrii-f-t27.git
cd dmitrii-f-t27/ecc-starter
./install.sh          # копирует в ~/.claude/ (глобально)
```

Либо в конкретный проект: `./install.sh /path/to/trinity` — положит всё в
`/path/to/trinity/.claude/`.

Скрипт ничего не перезаписывает молча: существующие файлы пропускает и сообщает об этом.

> Альтернатива: поставить весь ECC как плагин (`/plugin marketplace add
> https://github.com/affaan-m/ECC`, затем `/plugin install ecc@ecc`) — но тогда
> в контекст поедут все 286 скиллов. Этот набор — осознанный минимум.

## Процесс обновления

Раз в несколько дней смотрим, что нового в ECC относительно закреплённого коммита:

```bash
git clone --depth 50 https://github.com/affaan-m/ECC /tmp/ecc && cd /tmp/ecc
git log --oneline ca185ef5f7667078a1e70a763bd3a9c71c48acf0..HEAD -- agents skills rules
```

Добавляем **только необходимое** под стек, обновляем этот README (пин коммита и таблицы).
