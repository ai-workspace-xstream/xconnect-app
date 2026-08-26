#!/usr/bin/env bash
set -euo pipefail

APP_BIN="/opt/xconnect/xconnect"
if command -v setcap >/dev/null 2>&1 && [[ -x "$APP_BIN" ]]; then
  # The desktop runtime creates its named system tunnel interface directly;
  # grant only the networking capabilities required for that operation.
  setcap cap_net_admin,cap_net_raw+ep "$APP_BIN" || true
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi
