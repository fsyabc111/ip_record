#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if pgrep -x IPRecord >/dev/null; then
  echo 'IP Record is running. Quit it from its menu before replacing the application.' >&2
  exit 1
fi
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
ditto 'dist/IP Record.app' "$HOME/Applications/IP Record.app"
codesign --verify --strict "$HOME/Applications/IP Record.app"
echo "Installed: $HOME/Applications/IP Record.app"
if [[ "${1:-}" == '--open' ]]; then open "$HOME/Applications/IP Record.app"; fi
