#!/usr/bin/env bash
# Export Paperclip company + agents (names, roles, reporting, adapters,
# instructions, enabled skills, models) into a portable tree suitable for git.
# Uses the Paperclip CLI / board API. Secret values (API keys, tokens) are
# stripped and replaced with ${VAR} placeholders.
#
# Usage (on the Paperclip host, as a user who can call the API — typically
# paperclip, with ~/.paperclip/auth.json already logged in):
#   scripts/export-paperclip-agents.sh [outdir]
# Env:
#   PAPERCLIP_API_BASE  default http://127.0.0.1:3100
#   PAPERCLIPAI_VERSION default 2026.1023.0
set -euo pipefail

OUT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -z "$OUT" ]; then
  OUT="${REPO_ROOT}/paperclip-agents"
fi
API_BASE="${PAPERCLIP_API_BASE:-http://127.0.0.1:3100}"
PC_VERSION="${PAPERCLIPAI_VERSION:-2026.1023.0}"
INCLUDE="${PAPERCLIP_EXPORT_INCLUDE:-company,agents,skills}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "need $1" >&2; exit 1; }; }
need_cmd python3
need_cmd npx

pc() {
  npx --yes "paperclipai@${PC_VERSION}" "$@" --api-base "$API_BASE" --json
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Listing companies via ${API_BASE}"
# npx may print warnings; take the last JSON value
pc company list > "$TMP/list.raw" 2>"$TMP/list.err" || {
  echo "company list failed" >&2
  cat "$TMP/list.err" >&2
  exit 1
}

python3 - "$TMP/list.raw" "$TMP/companies.json" <<'PY'
import json,sys
raw=open(sys.argv[1],encoding="utf-8",errors="replace").read()
dec=json.JSONDecoder()
objs=[]
s=raw
while s:
    s=s.lstrip()
    if not s: break
    start=min((i for i,ch in ((s.find("{"),"{"),(s.find("["), "[")) if i>=0), default=-1)
    if start<0: break
    obj,end=dec.raw_decode(s[start:])
    objs.append(obj)
    s=s[start+end:]
items=[]
for obj in objs:
    if isinstance(obj,list):
        items.extend(obj)
    elif isinstance(obj,dict) and "id" in obj:
        items.append(obj)
    elif isinstance(obj,dict):
        items.extend(obj.get("companies") or obj.get("items") or [])
# unique
seen=set(); out=[]
for c in items:
    if isinstance(c,dict) and c.get("id") and c["id"] not in seen:
        seen.add(c["id"]); out.append(c)
if not out:
    raise SystemExit("no companies in CLI output")
json.dump(out, open(sys.argv[2],"w"), ensure_ascii=False, indent=2)
print("companies:", ", ".join(f"{c.get('name')} ({c['id']})" for c in out))
PY

mkdir -p "$OUT"
# Keep existing out contents only after a successful per-company export.

while IFS= read -r line; do
  name="${line%%	*}"
  cid="${line##*	}"
  [ -n "$cid" ] || continue
  echo "Exporting company $name ($cid)"
  dest="$TMP/raw/$name"
  mkdir -p "$dest"
  npx --yes "paperclipai@${PC_VERSION}" company export "$cid" \
    --out "$dest" --include "$INCLUDE" --force --api-base "$API_BASE" \
    > "$TMP/export-$name.log" 2>&1 || {
      echo "export failed for $name" >&2
      cat "$TMP/export-$name.log" >&2
      exit 1
    }
  tail -5 "$TMP/export-$name.log" || true
done < <(python3 -c 'import json,sys; cs=json.load(open(sys.argv[1]));
[print(c.get("name") or c["id"], c["id"], sep="\t") for c in cs]' "$TMP/companies.json")

# Enrich + sanitize into $OUT
python3 - "$TMP" "$OUT" "$API_BASE" <<'PY'
import json, os, re, shutil, hashlib, sys, urllib.request
from pathlib import Path

tmp, out, api_base = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
raw_root = tmp / "raw"
companies = json.loads((tmp / "companies.json").read_text())

# Board token from the paperclip CLI store. Never printed.
def load_token():
    home = Path(os.path.expanduser("~"))
    auth = home / ".paperclip" / "auth.json"
    if not auth.exists():
        return None
    data = json.loads(auth.read_text())
    creds = (data.get("credentials") or {})
    for key in (api_base, api_base.rstrip("/")):
        if key in creds and creds[key].get("token"):
            return creds[key]["token"]
    # first entry
    for v in creds.values():
        if isinstance(v, dict) and v.get("token"):
            return v["token"]
    return None

TOKEN = load_token()

def api(path):
    if not TOKEN:
        return None
    req = urllib.request.Request(
        api_base.rstrip("/") + path,
        headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"API {path} failed: {type(e).__name__}", file=sys.stderr)
        return None

SECRET_KEY_RE = re.compile(
    r"(api[_-]?key|token|secret|password|authorization|private[_-]?key|cookie|credential|access[_-]?key)",
    re.I,
)
SECRET_VAL_RE = re.compile(
    r"\b(AIza[0-9A-Za-z_-]{20,}|sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9._-]{10,})\b"
)
ENV_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]+$")

def placeholder_for(key: str) -> str:
    k = re.sub(r"[^A-Za-z0-9_]+", "_", key).strip("_")
    if not k:
        k = "SECRET"
    return "${" + k + "}"

def looks_secret_value(val: str) -> bool:
    if not isinstance(val, str):
        return False
    s = val.strip()
    if not s or s.startswith("${") and s.endswith("}"):
        return False
    if SECRET_VAL_RE.search(s):
        return True
    if len(s) >= 24 and re.fullmatch(r"[A-Za-z0-9+/=._-]{24,}", s):
        return True
    return False

def sanitize(obj, key_hint=""):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if SECRET_KEY_RE.search(str(k)) and not isinstance(v, (dict, list)):
                # keep empty defaults; replace non-empty secret values
                if v in ("", None, [], {}):
                    out[k] = v
                elif isinstance(v, str) and (v.startswith("${") or v == ""):
                    out[k] = v
                else:
                    name = k if ENV_NAME_RE.match(str(k)) else key_hint or str(k)
                    out[k] = placeholder_for(str(name))
            else:
                out[k] = sanitize(v, str(k))
        return out
    if isinstance(obj, list):
        return [sanitize(x, key_hint) for x in obj]
    if isinstance(obj, str) and looks_secret_value(obj):
        return placeholder_for(key_hint or "SECRET")
    return obj

def slugify(name: str, fallback: str) -> str:
    table = {
        "Мастер": "master",
        "Тимлид": "teamlead",
        "Дизайнер": "designer",
        "Мобилка": "mobile",
        "Фронт": "frontend",
        "Бэк": "backend",
        "aso специалист": "aso",
        "Docs": "docs",
    }
    if name in table:
        return table[name]
    s = name.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or fallback

def sanitize_text(text: str) -> str:
    return SECRET_VAL_RE.sub(lambda m: "${REDACTED}", text)

# Reset destination companies we will rewrite, keep README if present
out.mkdir(parents=True, exist_ok=True)

index = {"exportedAt": None, "apiBase": api_base, "companies": []}
from datetime import datetime, timezone
index["exportedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

for company in companies:
    cname = company.get("name") or company["id"]
    cid = company["id"]
    src = raw_root / cname
    if not src.exists():
        # maybe the export used a different folder name
        cands = [p for p in raw_root.iterdir() if p.is_dir()]
        src = cands[0] if len(cands) == 1 else None
        if src is None:
            print("missing export dir for", cname, file=sys.stderr)
            continue

    dest = out / cname
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    # Copy official package into packages/ (importable), sanitizing text
    pkg = dest / "package"
    shutil.copytree(src, pkg, ignore=shutil.ignore_patterns(".git"))
    for p in pkg.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".zip"}:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except Exception:
            continue
        new = sanitize_text(text)
        if p.suffix in {".yaml", ".yml"} or p.name.endswith(".yaml"):
            lines = new.splitlines(keepends=True)
            rebuilt = []
            i = 0
            while i < len(lines):
                rebuilt.append(lines[i])
                if "kind:" in lines[i] and "secret" in lines[i]:
                    j = i + 1
                    while j < len(lines) and j <= i + 5:
                        stripped = lines[j].lstrip()
                        if stripped.startswith("default:"):
                            raw = stripped.split(":", 1)[1].strip()
                            if raw not in ('""', "''", "", "null", "~"):
                                ws = lines[j][: len(lines[j]) - len(lines[j].lstrip())]
                                ending = "\n" if lines[j].endswith("\n") else ""
                                rebuilt.append(ws + 'default: ""' + ending)
                                i = j
                            break
                        # stop if we leave the block
                        if stripped and not lines[j].startswith(" ") and not lines[j].startswith("\t"):
                            break
                        j += 1
                i += 1
            new = "".join(rebuilt)
        if new != text:
            p.write_text(new, encoding="utf-8")

    # Company-level metadata (no emails/user ids if possible)
    meta = {
        "name": cname,
        "sourceCompanyId": cid,
        "status": company.get("status"),
        "issuePrefix": company.get("issuePrefix"),
        "description": company.get("description"),
        "note": "sourceCompanyId is from the origin server and will change on import.",
    }
    (dest / "company.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    for name in ("COMPANY.md", "README.md", ".paperclip.yaml"):
        sp = pkg / name
        if sp.exists() and name.endswith(".md"):
            shutil.copy2(sp, dest / name)

    # API enrichment
    agents = api(f"/api/companies/{cid}/agents") or []
    if isinstance(agents, dict):
        agents = agents.get("agents") or agents.get("items") or []
    id_to_name = {a["id"]: a.get("name") for a in agents if isinstance(a, dict) and a.get("id")}
    id_to_url = {a["id"]: a.get("urlKey") for a in agents if isinstance(a, dict) and a.get("id")}

    # Map official package folder slug -> agent (by order in yaml sidebar + names)
    yaml_path = pkg / ".paperclip.yaml"
    # official folders under package/agents
    pkg_agents = {}
    agents_dir = pkg / "agents"
    if agents_dir.exists():
        for d in agents_dir.iterdir():
            if d.is_dir():
                pkg_agents[d.name] = d

    # Guess mapping: urlKey if it matches a folder, else folder names from README
    used = set()
    friendly = dest / "agents"
    friendly.mkdir(exist_ok=True)

    def adapter_sanitized(conf):
        ac = conf.get("adapterConfig") or {}
        if not isinstance(ac, dict):
            return {"type": conf.get("adapterType"), "config": ac}
        ac = sanitize(ac)
        # env: keep keys, replace any leftover values
        env = ac.get("env")
        if isinstance(env, dict):
            clean = {}
            for ek, ev in env.items():
                if isinstance(ev, dict):
                    item = dict(ev)
                    if item.get("kind") == "secret":
                        item["default"] = ""
                        # also allow installer to inject
                        item["valueFrom"] = placeholder_for(ek)
                    clean[ek] = item
                else:
                    clean[ek] = placeholder_for(ek) if looks_secret_value(str(ev)) else ev
            ac["env"] = clean
        return {"type": conf.get("adapterType"), "config": ac}

    for a in agents:
        aid = a["id"]
        conf = api(f"/api/agents/{aid}/configuration") or a
        skills = api(f"/api/agents/{aid}/skills") or {}
        desired = skills.get("desiredSkills") if isinstance(skills, dict) else []
        entries = []
        if isinstance(skills, dict):
            for e in skills.get("desiredSkillEntries") or skills.get("entries") or []:
                if not isinstance(e, dict):
                    continue
                entries.append({
                    "name": e.get("name") or e.get("key") or e.get("slug"),
                    "enabled": e.get("enabled", e.get("desired")),
                })
        url_key = a.get("urlKey") or ""
        folder = url_key if url_key in pkg_agents else None
        # fallback: match by sidebar names later; try agent / agent-N via role+reports later
        name = a.get("name") or url_key or aid
        slug = slugify(name, folder or aid[:8])
        # avoid collisions
        base = slug
        n = 2
        while slug in used:
            slug = f"{base}-{n}"
            n += 1
        used.add(slug)

        reports_id = conf.get("reportsTo") or a.get("reportsTo")
        rec = {
            "name": name,
            "title": conf.get("title") or a.get("title"),
            "role": conf.get("role") or a.get("role"),
            "sourceAgentId": aid,
            "urlKey": url_key,
            "packageSlug": folder,
            "reportsTo": id_to_name.get(reports_id) if reports_id else None,
            "reportsToSourceAgentId": reports_id,
            "adapter": adapter_sanitized(conf if isinstance(conf, dict) else a),
            "runtime": conf.get("runtimeConfig") or a.get("runtimeConfig"),
            "permissions": conf.get("permissions") or a.get("permissions"),
            "desiredSkills": desired,
            "skillEntries": entries,
        }
        agent_dir = friendly / slug
        agent_dir.mkdir()
        (agent_dir / "agent.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
        # copy instructions from package if we can find them
        src_dir = None
        if folder and folder in pkg_agents:
            src_dir = pkg_agents[folder]
        # If urlKey is a UUID, official export used generic slugs; copy later by yaml order
        if src_dir:
            for md in src_dir.glob("*.md"):
                (agent_dir / md.name).write_text(sanitize_text(md.read_text(encoding="utf-8", errors="replace")), encoding="utf-8")
            rec["packageSlug"] = folder
            (agent_dir / "agent.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")

    # Map official package folders by YAML frontmatter name: (exact), not substring.
    fm_name = {}
    for slug, d in pkg_agents.items():
        md = d / "AGENTS.md"
        if not md.exists():
            continue
        text = md.read_text(encoding="utf-8", errors="replace")
        m = re.search(r'(?m)^name:\s*"?([^"\n]+)"?\s*$', text)
        if m:
            fm_name[m.group(1).strip()] = (slug, d, text)
    id_pat = re.compile(r"(—\s*)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\s*—)", re.I)
    # also strip stale origin-server agent ids in official package instructions
    for slug, d in pkg_agents.items():
        md = d / "AGENTS.md"
        if md.exists():
            text = md.read_text(encoding="utf-8", errors="replace")
            new = id_pat.sub(r"\1\2", sanitize_text(text))
            if new != text:
                md.write_text(new, encoding="utf-8")
    for s in sorted(used):
        aj = friendly / s / "agent.json"
        rec = json.loads(aj.read_text())
        hit = fm_name.get(rec.get("name") or "")
        if not hit:
            continue
        slug, d, text = hit
        rec["packageSlug"] = slug
        aj.write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n")
        (friendly / s / "AGENTS.md").write_text(id_pat.sub(r"\1\2", sanitize_text(text)), encoding="utf-8")

        index["companies"].append({
        "name": cname,
        "sourceCompanyId": cid,
        "agents": [
            {
                "slug": s,
                "name": json.loads((friendly / s / "agent.json").read_text())["name"],
                "role": json.loads((friendly / s / "agent.json").read_text())["role"],
            }
            for s in sorted(used)
        ],
        "importPath": str(Path(cname) / "package"),
    })

(out / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n")
print("Wrote", out)
print("companies", len(index["companies"]))
PY

# Write a short README if missing
if [ ! -f "$OUT/README.md" ]; then
  cat > "$OUT/README.md" << 'MD'
# Экспорт агентов Paperclip

Это портативный снимок компаний и агентов (без секретов). Его можно хранить в git и периодически обновлять.

## Содержимое

- `index.json` — список компаний и агентов.
- `<компания>/company.json` — метаданные компании.
- `<компания>/agents/<slug>/agent.json` — имя, роль, кому подчиняется, адаптер, модель, включённые навыки. Секреты заменены на `${VAR}`.
- `<компания>/agents/<slug>/AGENTS.md` — инструкция агента.
- `<компания>/package/` — официальный пакет Paperclip (`company export`), его же использует импорт.

## Обновление снимка

На сервере с запущенным Paperclip и сохранённым входом CLI (`npx paperclipai auth whoami --api-base http://127.0.0.1:3100`):

```bash
cd /root/src/server-bootstrap
sudo -u paperclip -H ./scripts/export-paperclip-agents.sh
git add paperclip-agents
git commit -m "Update Paperclip agents export"
git push
```

Секреты (API-ключи, токены) в репозиторий не попадают. После импорта на новом сервере их нужно задать заново (переменные окружения или вход в адаптер).
MD
fi

echo "Export complete: $OUT"
