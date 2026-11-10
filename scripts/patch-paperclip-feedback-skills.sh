#!/usr/bin/env bash
# Re-apply PAPERCLIP_FEEDBACK_SKILL_KEYS = [] in @paperclipai/adapter-utils
# so Paperclip does not auto-enable suggestion-box / complain after an npm
# cache refresh or Paperclip upgrade. Safe to run repeatedly.
set -euo pipefail

USER_NAME="${PAPERCLIP_USER:-paperclip}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [ -z "$HOME_DIR" ]; then
  echo "User $USER_NAME not found" >&2
  exit 1
fi

python3 - "$HOME_DIR" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pattern = re.compile(
    r"export\s+const\s+PAPERCLIP_FEEDBACK_SKILL_KEYS\s*=\s*\[[^\]]*\]\s*;",
    re.S,
)
replacement = "export const PAPERCLIP_FEEDBACK_SKILL_KEYS = [];"
changed = 0
searched = 0
for base in (root / ".npm", root / ".cache"):
    if not base.exists():
        continue
    for path in base.rglob("server-utils.js"):
        if "adapter-utils" not in str(path) or "/dist/" not in str(path).replace("\\", "/"):
            continue
        if path.name.endswith(".map"):
            continue
        searched += 1
        text = path.read_text(errors="replace")
        if "PAPERCLIP_FEEDBACK_SKILL_KEYS" not in text:
            continue
        new, n = pattern.subn(replacement, text, count=1)
        if n and new != text:
            path.write_text(new)
            changed += 1
            print("patched", path)
        elif "PAPERCLIP_FEEDBACK_SKILL_KEYS = [];" in text or "PAPERCLIP_FEEDBACK_SKILL_KEYS=[];" in text:
            print("already patched", path)
print(f"searched={searched} patched={changed}")
if searched == 0:
    sys.exit(0)
PY

if systemctl is-active --quiet paperclip; then
  echo "Restart Paperclip to load the patched module? (script does not restart it automatically)"
fi
