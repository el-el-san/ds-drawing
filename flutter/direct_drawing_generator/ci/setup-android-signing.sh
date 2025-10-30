#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "::error::flutter command not found. Install Flutter and add it to PATH." >&2
  exit 1
fi

if [[ ! -d android ]]; then
  echo "Android platform scaffolding not found. Running flutter create..."
  flutter create --org io.koseri --platforms android --no-pub .
fi

MANIFEST_MAIN="android/app/src/main/AndroidManifest.xml"
if [[ -f "$MANIFEST_MAIN" ]]; then
  python3 - "$MANIFEST_MAIN" <<'PY'
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
text = manifest_path.read_text(encoding="utf-8")
permission_line = '<uses-permission android:name="android.permission.INTERNET" />'

if permission_line in text:
    sys.exit(0)

lines = text.splitlines()
insert_at = None
for idx, line in enumerate(lines):
    if '<application' in line:
        insert_at = idx
        break

if insert_at is None:
    lines.append('    ' + permission_line)
else:
    lines.insert(insert_at, '    ' + permission_line)

updated = "\n".join(lines)
if not updated.endswith("\n"):
    updated += "\n"

manifest_path.write_text(updated, encoding="utf-8")
PY
fi

KEYSTORE_B64="${ANDROID_KEYSTORE_B64:-}"
STORE_PASSWORD="${ANDROID_KEYSTORE_PASSWORD:-}"
KEY_ALIAS="${ANDROID_KEY_ALIAS:-koseriReleaseV2}"
KEY_PASSWORD="${ANDROID_KEY_PASSWORD:-$STORE_PASSWORD}"
KEYSTORE_PATH="android/app/upload.keystore"
KEY_PROPS="android/key.properties"

if [[ -z "$KEYSTORE_B64" || -z "$STORE_PASSWORD" ]]; then
  echo "::error::ANDROID_KEYSTORE_B64 / ANDROID_KEYSTORE_PASSWORD must be set" >&2
  exit 1
fi

mkdir -p "$(dirname "$KEYSTORE_PATH")"
printf '%s' "$KEYSTORE_B64" | base64 --decode > "$KEYSTORE_PATH"
chmod 600 "$KEYSTORE_PATH"

cat > "$KEY_PROPS" <<KEYPROPS
storeFile=../app/upload.keystore
storePassword=$STORE_PASSWORD
keyAlias=$KEY_ALIAS
keyPassword=$KEY_PASSWORD
KEYPROPS

ci/ensure-android-signing.sh

echo "Android signing is configured. Build with:\n  flutter build apk --release" 
