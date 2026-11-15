#!/usr/bin/env bash
# Release a new version of the Vendo site.
#
#   1. Add an entry at the top of RELEASES in index.html (version, date, title, notes).
#   2. Run: ./release.sh 0.11.0
#   3. Check the commit, then push: git push origin main --follow-tags
#
# Versions stay at 0.x while Vendo is a demo. 1.0.0 is the public launch.
# Bump the last number for fixes (0.10.1), the middle number for new features (0.11.0).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: ./release.sh <version>   e.g. ./release.sh 0.11.0" >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "v$VERSION already exists. Pick a new version number." >&2; exit 1
fi
OTHER=$(git status --porcelain --untracked-files=no | grep -vE '^.. (index\.html|sw\.js|CHANGELOG\.md|README\.md|package\.json)$' || true)
if [[ -n "$OTHER" ]]; then
  echo "Commit or put away these changes first:" >&2; echo "$OTHER" >&2; exit 1
fi

# Read RELEASES from index.html, check the newest entry, and write CHANGELOG.md.
TITLE=$(node - "$VERSION" <<'JS'
const fs = require("fs");
const want = process.argv[2];
const src = fs.readFileSync("index.html", "utf8");
const m = src.match(/const RELEASES=(\[[\s\S]*?\]);\n/);
if (!m) { console.error("Couldn't find RELEASES in index.html."); process.exit(1); }
const releases = Function(`return ${m[1]}`)();
if (releases[0].v !== want) {
  console.error(`The newest entry in RELEASES is ${releases[0].v}. Add ${want} at the top first.`); process.exit(1);
}
const md = ["# What's new in Vendo", "",
  "Versions start at 0 while Vendo is a demo. 1.0.0 will be the public launch.", ""];
for (const r of releases) {
  md.push(`## ${r.v} · ${r.t}`, "", `_${r.d}_`, "", ...r.n.map(n => `- ${n}`), "");
}
fs.writeFileSync("CHANGELOG.md", md.join("\n"));
process.stdout.write(releases[0].t);
JS
)

# Keep package.json (the iPhone app's version) in step.
if [[ -f package.json ]]; then
  sed -i.bak -E "s/^  \"version\": \"[0-9.]+\",/  \"version\": \"$VERSION\",/" package.json && rm -f package.json.bak
fi

# Keep the offline cache name in step, so phones pick up the new version.
sed -i.bak -E "s/^const VERSION = \"[0-9.]+\";/const VERSION = \"$VERSION\";/" sw.js && rm -f sw.js.bak
grep -q "const VERSION = \"$VERSION\";" sw.js || { echo "Couldn't update the version in sw.js." >&2; exit 1; }

git add index.html sw.js CHANGELOG.md README.md release.sh $( [[ -f package.json ]] && echo package.json )
git commit -q -m "Release v$VERSION: $TITLE"
git tag -a "v$VERSION" -m "Vendo $VERSION: $TITLE"
echo "Released v$VERSION ($TITLE). Push with: git push origin main --follow-tags"
