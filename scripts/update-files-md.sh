#!/usr/bin/env bash
# Regenerate FILES.md from git ls-files.
# Run after adding/renaming any tracked file to keep FILES.md current.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%d)

cat > FILES.md <<EOF
# FILES.md — SHA-pinned raw URLs for all tracked files

> Generated from commit \`$SHA\` on $DATE.
> Verify current: \`git rev-parse HEAD\` should match the SHA above.
> Stale? Run \`./scripts/update-files-md.sh\` to regenerate.

Each URL below pins to commit \`$SHA\` — immune to mutable-ref CDN caches.

| File | Raw URL |
|------|---------|
EOF

git ls-files | sort | while read -r file; do
    echo "| \`$file\` | https://raw.githubusercontent.com/slittycode/input-delay/$SHA/$file |"
done >> FILES.md

echo "FILES.md regenerated at commit $SHA ($DATE)"
