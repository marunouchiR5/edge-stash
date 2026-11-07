#!/usr/bin/env bash
# Native regression test using synthetic apps only. Requires Accessibility on the terminal.
# Temporarily restarts EdgeStash; uses launch arguments and never changes saved preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
qa_dir=$(mktemp -d /private/tmp/edgestash-coexistence.XXXXXX)
trap 'rm -rf "$qa_dir"' EXIT
swiftc Scripts/qa/WindowFixture.swift -o "$qa_dir/Fixture"
swiftc Scripts/qa/WindowCoexistence.swift -o "$qa_dir/Test"
python3 - "$qa_dir" <<'PY'
import pathlib, plistlib, shutil, sys
root = pathlib.Path(sys.argv[1])
for role in ['Left', 'Right', 'Main']:
    app = root / (role + '.app') / 'Contents'
    (app / 'MacOS').mkdir(parents=True)
    shutil.copy2(root / 'Fixture', app / 'MacOS/Fixture')
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'io.github.marunouchir5.EdgeStash.QA.' + role.lower(),
        'CFBundleExecutable': 'Fixture', 'CFBundleName': 'EdgeStash QA ' + role,
        'CFBundlePackageType': 'APPL', 'QARole': role,
    }))
PY
"$qa_dir/Test" "${1:-/Applications/EdgeStash.app}" "$qa_dir"
