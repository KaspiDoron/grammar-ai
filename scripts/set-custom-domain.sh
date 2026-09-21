#!/bin/bash
# Points the Typfix landing page at your own domain on GitHub Pages.
# Run this AFTER you have bought the domain and added the DNS records from
# docs/DOMAIN.md.
#
#   scripts/set-custom-domain.sh typfix.com
set -euo pipefail
DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "usage: $0 <domain>   e.g. $0 typfix.com" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# GitHub Pages serves a domain named in a CNAME file at the site root.
echo "$DOMAIN" > "$ROOT/site/CNAME"
echo "==> Wrote site/CNAME ($DOMAIN)"

# Tell the GitHub Pages settings about the custom domain too.
if command -v gh >/dev/null 2>&1; then
    gh api -X PUT repos/KaspiDoron/grammar-ai/pages -f cname="$DOMAIN" >/dev/null 2>&1 \
        && echo "==> Set the Pages custom domain via the API" \
        || echo "note: couldn't set it via the API - set it in the repo Settings > Pages instead"
fi

cd "$ROOT"
git add site/CNAME
git commit -q -m "Point the landing page at $DOMAIN" || true
git push -q origin main || true
echo "==> Done. Once DNS has propagated (minutes to a few hours) and GitHub has"
echo "    issued the HTTPS certificate, https://$DOMAIN shows the landing page."
