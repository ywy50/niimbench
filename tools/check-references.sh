#!/bin/sh
# Fail when the tree names niimprint or libreniim anywhere but the README's
# credit line.
#
#   tools/check-references.sh
#
# niimbench is its own project. The README says it is inspired by niimprint,
# once; code comments, docs and tests describe what niimbench does in its own
# terms instead of pointing at another implementation.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
hits=$(git ls-files --cached --others --exclude-standard -z \
  | xargs -0 grep -nIiE 'niimprint|libreniim' -- 2>/dev/null \
  | grep -v '^README\.md:[0-9]*:A local label bench for Niimbot printers, written in Zig\. niimbench is inspired by \[niimprint\]' \
  | grep -v '^tools/check-references\.sh:' || true)
if [ -n "$hits" ]; then
  echo "check-references: niimprint or libreniim is named outside the README's credit line:"
  echo "$hits" | sed 's/^/  /'
  exit 1
fi
echo "references ok"
