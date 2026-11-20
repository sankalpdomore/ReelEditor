#!/bin/zsh
# Writes Sources/ReelEditor/PhosphorCodes.swift: the Phosphor code of every icon the app names, Icon("scissors") and
# the like, read from the same Phosphor version the web app loads (@phosphor-icons/web 2.1.2). Bold and Fill share
# their codes. Run it after using a new icon name:
#   ./phosphor-codes.sh
set -euo pipefail
cd "$(dirname "$0")"
CSS=$(curl -sfL https://cdn.jsdelivr.net/npm/@phosphor-icons/web@2.1.2/src/bold/style.css)
# Every lowercase string in the views is a candidate (icon names are often picked in a condition or passed on), and
# only the ones Phosphor has are kept, so nothing is missed and nothing else gets in.
NAMES=$(grep -rhoE '"[a-z][a-z0-9-]*"' Sources/ReelEditor --include='*.swift' --exclude=PhosphorCodes.swift | tr -d '"' | sort -u)
OUT=Sources/ReelEditor/PhosphorCodes.swift
{
  echo "// Made by phosphor-codes.sh from @phosphor-icons/web 2.1.2. Do not edit by hand: name the icon in a view and run the script."
  echo "enum PhosphorCodes {"
  echo "  static let map: [String: UInt32] = ["
  for n in $(printf '%s\n' $NAMES); do
    code=$(print -r -- "$CSS" | grep -A1 "^\.ph-bold\.ph-$n:before" | sed -n 's/.*content: "\\\([0-9a-f]*\)".*/\1/p' | head -1 || true) 
    if [[ -n "$code" ]]; then echo "    \"$n\": 0x$code,"; fi
  done
  echo "  ]"
  echo "}"
} > $OUT
echo "Wrote $OUT"
