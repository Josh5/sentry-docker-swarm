#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <file> <needle> <replacement>" >&2
    exit 1
fi

file=$1
needle=$2
replacement=$3

[ -f "$file" ] || exit 0

if ! grep -Fxq "$needle" "$file"; then
    exit 0
fi

tmp_file=$(mktemp)
awk -v needle="$needle" -v replacement="$replacement" '
    !done && $0 == needle {print replacement; done=1; next}
    {print}
' "$file" >"$tmp_file"
mv "$tmp_file" "$file"
