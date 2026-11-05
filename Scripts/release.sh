#!/usr/bin/env bash
# Builds the release zip, optionally notarizes it, and updates Casks/edgestash.rb.
#
#   SIGN_IDENTITY   "Developer ID Application: …" (default "-" = ad-hoc, not Gatekeeper-friendly)
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials …); enables notarization
#   PUBLISH=1       also create the GitHub release (needs `gh auth login` or GH_TOKEN)
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env

ZIP="dist/EdgeStash-$MARKETING_VERSION.zip"
Scripts/package_app.sh

zip_app() { rm -f "$ZIP"; ditto -c -k --keepParent dist/EdgeStash.app "$ZIP"; }
zip_app
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/EdgeStash.app
  zip_app
fi

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
sed -i '' -e "s/^  version \".*\"/  version \"$MARKETING_VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/edgestash.rb
echo "$ZIP  sha256=$SHA"

if [[ "${PUBLISH:-0}" == 1 ]]; then
  gh release create "v$MARKETING_VERSION" "$ZIP" --title "EdgeStash $MARKETING_VERSION" --generate-notes
fi
