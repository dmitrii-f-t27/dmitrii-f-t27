#!/usr/bin/env bash
# Устанавливает ECC Starter Kit в ~/.claude/ (по умолчанию)
# или в <проект>/.claude/, если передан путь к проекту.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -ge 1 ]; then
  DEST="$1/.claude"
else
  DEST="$HOME/.claude"
fi

mkdir -p "$DEST/agents" "$DEST/skills" "$DEST/rules/ecc"

copied=0
skipped=0

copy_file() {
  local from="$1" to="$2"
  if [ -e "$to" ]; then
    echo "  пропущен (уже есть): $to"
    skipped=$((skipped + 1))
  else
    mkdir -p "$(dirname "$to")"
    cp "$from" "$to"
    copied=$((copied + 1))
  fi
}

echo "Агенты -> $DEST/agents/"
for f in "$SRC"/agents/*.md; do
  copy_file "$f" "$DEST/agents/$(basename "$f")"
done

echo "Скиллы -> $DEST/skills/"
for d in "$SRC"/skills/*/; do
  name="$(basename "$d")"
  if [ -e "$DEST/skills/$name" ]; then
    echo "  пропущен (уже есть): $DEST/skills/$name"
    skipped=$((skipped + 1))
  else
    cp -R "$d" "$DEST/skills/$name"
    copied=$((copied + 1))
  fi
done

echo "Правила -> $DEST/rules/ecc/"
for d in "$SRC"/rules/*/; do
  name="$(basename "$d")"
  if [ -e "$DEST/rules/ecc/$name" ]; then
    echo "  пропущен (уже есть): $DEST/rules/ecc/$name"
    skipped=$((skipped + 1))
  else
    cp -R "$d" "$DEST/rules/ecc/$name"
    copied=$((copied + 1))
  fi
done

echo
echo "Готово: скопировано $copied, пропущено $skipped."
echo "Хуки continuous-learning-v2 подключаются отдельно — см. skills/continuous-learning-v2/SKILL.md."
