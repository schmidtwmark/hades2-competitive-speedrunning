#!/usr/bin/env bash
# Build Hades 2 Competitive Speedrunning's Thunderstore upload and check it against Thunderstore's
# package format. mod/src/manifest.json is the one source of the name, version,
# description and dependencies; thunderstore/ holds the icon, the store README
# and the changelog. Writes, in build/ (or $OUT):
#   schmidtwmark-Hades_2_Competitive_Speedrunning-<version>.zip   flat zip: manifest.json, icon.png,
#                                          README.md, CHANGELOG.md, LICENSE, the mod
#   thunderstore.toml                      the matching tcli config, for publishing
# Publishing needs a service-account token of the Thunderstore team
# "schmidtwmark" (the plugin folder is schmidtwmark-Hades_2_Competitive_Speedrunning):
#   TCLI_AUTH_TOKEN=... tcli publish --config-path build/thunderstore.toml --file build/<zip>
# .github/workflows/thunderstore.yml runs both.
#   scripts/thunderstore-package.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
mkdir -p "$OUT"
python3 - "$ROOT" "$OUT" <<'PY'
import json, re, struct, sys, zipfile
from pathlib import Path

root, out = Path(sys.argv[1]), Path(sys.argv[2])
NAMESPACE = "schmidtwmark"
COMMUNITY = "hades-ii"
CATEGORIES = ["mods", "gameplay", "ai-generated"]
problems = []

def need(ok, what):
    if not ok:
        problems.append(what)

src = root / "mod" / "src"
store = root / "thunderstore"
m = json.loads((src / "manifest.json").read_text(encoding="utf-8"))
name, version = m.get("name", ""), m.get("version_number", "")
need(re.fullmatch(r"[A-Za-z0-9_]{1,128}", name or ""), "manifest name: letters, digits and _ only")
need(re.fullmatch(r"\d+\.\d+\.\d+", version or ""), "manifest version_number: Major.Minor.Patch")
need(0 < len(m.get("description", "")) <= 250, "manifest description: 1-250 characters")
need(isinstance(m.get("website_url"), str) and m["website_url"].startswith("https://"), "manifest website_url: a https:// link")
deps = m.get("dependencies", [])
need(isinstance(deps, list) and all(re.fullmatch(r"[A-Za-z0-9_]+-[A-Za-z0-9_]+-\d+\.\d+\.\d+", d) for d in deps),
     "manifest dependencies: Team-Name-x.y.z strings")

# The dependencies are the versions the installer pins (and the mod is tested with).
pins = {}
for line in (root / "install" / "packages.txt").read_text().splitlines():
    parts = line.split()
    if len(parts) >= 2 and not line.startswith("#"):
        pins[parts[0]] = parts[1]
for d in deps:
    full, ver = d.rsplit("-", 1)
    need(pins.get(full) == ver, f"dependency {d}: install/packages.txt pins {full} {pins.get(full)}")
# The race server's latest version must be this one (it tells older clients to update).
latest = re.search(r'LATEST_MOD_VERSION = "([^"]+)"', (root / "server" / "src" / "versions.ts").read_text())
need(latest and latest.group(1) == version, f"server LATEST_MOD_VERSION {latest and latest.group(1)} != {version}")
main_version = re.search(r"local VERSION = '([^']+)'", (src / "main.lua").read_text())
need(main_version and main_version.group(1) == version, f"mod/src/main.lua VERSION {main_version and main_version.group(1)} != {version}")

icon = (store / "icon.png").read_bytes()
need(icon[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", icon[16:24]) == (256, 256), "thunderstore/icon.png: a 256x256 PNG")
for f in ("README.md", "CHANGELOG.md"):
    text = (store / f).read_text(encoding="utf-8")
    need(len(text.strip()) > 0, f"thunderstore/{f}: empty")
need(f"## {version}" in (store / "CHANGELOG.md").read_text(encoding="utf-8"), f"thunderstore/CHANGELOG.md: no '## {version}' section")

mod_files = sorted(p for p in src.iterdir() if p.is_file() and not p.name.startswith(".") and p.name != "bot.json")
need(any(p.name == "main.lua" for p in mod_files), "mod/src/main.lua missing")

if problems:
    print("Thunderstore package NOT built:")
    for p in problems:
        print("  - " + p)
    sys.exit(1)

zip_path = out / f"{NAMESPACE}-{name}-{version}.zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for p in mod_files:
        z.write(p, p.name)
    z.write(store / "icon.png", "icon.png")
    z.write(store / "README.md", "README.md")
    z.write(store / "CHANGELOG.md", "CHANGELOG.md")
    z.write(root / "LICENSE", "LICENSE")

toml = [
    "# Written by scripts/thunderstore-package.sh from mod/src/manifest.json; edit that instead.",
    "[config]", 'schemaVersion = "0.0.1"', "",
    "[package]", f'namespace = "{NAMESPACE}"', f'name = "{name}"', f'versionNumber = "{version}"',
    f"description = {json.dumps(m['description'])}", f'websiteUrl = "{m["website_url"]}"', "containsNsfwContent = false", "",
    "[package.dependencies]",
] + [f'{d.rsplit("-", 1)[0]} = "{d.rsplit("-", 1)[1]}"' for d in deps] + [
    "",
    "[build]", 'icon = "./icon.png"', 'readme = "./README.md"', f'outdir = "{out}"', "",
    "[publish]", 'repository = "https://thunderstore.io"', f'communities = [ "{COMMUNITY}", ]', "",
    "[publish.categories]", f"{COMMUNITY} = [ " + ", ".join(f'"{c}"' for c in CATEGORIES) + " ]", "",
]
(out / "thunderstore.toml").write_text("\n".join(toml))

with zipfile.ZipFile(zip_path) as z:
    names = z.namelist()
print(f"built {zip_path} ({zip_path.stat().st_size // 1024} KB, {len(names)} files)")
print(f"  {NAMESPACE}-{name} {version}; depends on {', '.join(deps)}")
print(f"  community {COMMUNITY}, categories {', '.join(CATEGORIES)}")
print(f"wrote {out / 'thunderstore.toml'}")
PY
