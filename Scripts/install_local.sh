#!/usr/bin/env bash
# Builds, signs with your first local signing identity, installs to /Applications and launches.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk 'NR==1 && /\)/ {print $2}')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
SIGN_IDENTITY="$SIGN_IDENTITY" ARCHS="${ARCHS:-$(uname -m)}" Scripts/package_app.sh
pkill -x EdgeStash 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/EdgeStash.app
cp -R dist/EdgeStash.app /Applications/
open /Applications/EdgeStash.app
echo "Installed and launched /Applications/EdgeStash.app"
