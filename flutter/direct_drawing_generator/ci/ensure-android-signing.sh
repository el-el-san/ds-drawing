#!/usr/bin/env bash
set -euo pipefail

GRADLE_FILE="android/app/build.gradle"
MANIFEST_FILE="android/app/src/main/AndroidManifest.xml"

if [[ ! -f "$GRADLE_FILE" ]]; then
  echo "::error::Missing $GRADLE_FILE; run this after flutter create" >&2
  exit 1
fi

if [[ -f "$MANIFEST_FILE" ]]; then
  python3 - "$MANIFEST_FILE" <<'PY'
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
text = manifest_path.read_text(encoding="utf-8")
permission = '<uses-permission android:name="android.permission.INTERNET" />'

if permission not in text:
    lines = text.splitlines()
    insert_at = None
    for idx, line in enumerate(lines):
        if '<application' in line:
            insert_at = idx
            break
    new_line = '    ' + permission
    if insert_at is None:
        lines.append(new_line)
    else:
        lines.insert(insert_at, new_line)
    updated = "\n".join(lines)
    if not updated.endswith("\n"):
        updated += "\n"
    manifest_path.write_text(updated, encoding="utf-8")
PY
fi

python3 - "$GRADLE_FILE" <<'PY'
import re
import sys
from pathlib import Path

gradle_path = Path(sys.argv[1])
text = gradle_path.read_text(encoding="utf-8")

# Inject keystoreProperties loader if absent
loader_snippet = """def keystoreProperties = new Properties()\ndef keystorePropertiesFile = rootProject.file('key.properties')\nif (keystorePropertiesFile.exists()) {\n    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n}\n\n"""
if "keystorePropertiesFile" not in text:
    marker = "android {\n"
    if marker not in text:
        raise SystemExit("android block not found in build.gradle")
    text = text.replace(marker, loader_snippet + marker, 1)

# Ensure signingConfigs.release block exists
signing_block = """    signingConfigs {\n        release {\n            if (keystoreProperties['storeFile']) {\n                storeFile = file(keystoreProperties['storeFile'])\n            }\n            if (keystoreProperties['storePassword']) {\n                storePassword = keystoreProperties['storePassword']\n            }\n            if (keystoreProperties['keyAlias']) {\n                keyAlias = keystoreProperties['keyAlias']\n            }\n            if (keystoreProperties['keyPassword']) {\n                keyPassword = keystoreProperties['keyPassword']\n            }\n        }\n    }\n\n"""
if "signingConfigs {" not in text:
    marker = "    buildTypes {"
    if marker not in text:
        raise SystemExit("buildTypes block not found in build.gradle")
    text = text.replace(marker, signing_block + marker, 1)

# Force release build to use release signing config
text = text.replace("signingConfig = signingConfigs.debug", "signingConfig = signingConfigs.release")

build_types_pattern = re.compile(
    r"    buildTypes \{\n        release \{\n.*?\n        \}\n    \}\n",
    re.DOTALL,
)
text = build_types_pattern.sub(
    "    buildTypes {\n        release {\n            signingConfig = signingConfigs.release\n        }\n    }\n",
    text,
    count=1,
)

# Remove template comment about debug signing if it is still present
text = text.replace("        // TODO: Add your own signing config for the release build.\n", "")
text = text.replace("        // Signing with the debug keys for now, so `flutter run --release` works.\n", "")

# Persist changes
gradle_path.write_text(text, encoding="utf-8")
PY
