#!/usr/bin/env bash
# make-entry-profile.sh — локальная генерация config-profile входной ноды (I→O каскад).
# Запуск на ПК в Git Bash. SSH на I1 не нужен: результат вставляется в панель
# (Config Profiles → entry-i1 → заменить JSON).
#
# Ссылки на выходы читаются из exit-links.local.txt (по одной vless:// на строку,
# порядок = приоритет: первая — O1, вторая — O2 и т.д.).
# exit-links.local.txt содержит секреты — НЕ коммитить в Git!
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LINKS="$HERE/exit-links.local.txt"
OUT="$HERE/entry-config-profile.json"

[[ -f "$LINKS" ]] || { echo "Нет $LINKS — создайте и вставьте vless-ссылки (по одной на строку)"; exit 1; }

# python или py (Windows)
PY=python
command -v python >/dev/null 2>&1 || PY=py

mapfile -t ARGS < <(grep -vE '^\s*(#|$)' "$LINKS" | sed 's/\r$//' | while read -r l; do printf -- '--exit\n%s\n' "$l"; done)
((${#ARGS[@]})) || { echo "В $LINKS нет ни одной ссылки"; exit 1; }

"$PY" "$HERE/gen_entry_profile.py" "${ARGS[@]}" \
  --target www.microsoft.com:443 --sni www.microsoft.com \
  --port 1443 --port-step 1000 \
  --out "$OUT"

echo
echo "Дальше: панель → Config Profiles → entry-i1 → заменить JSON содержимым файла:"
echo "  $OUT"
