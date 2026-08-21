#!/usr/bin/env bash
#
# n8n-pull.sh — trigger a source control pull on an n8n instance.
#
# Requires: N8N_BASE_URL, N8N_API_KEY
# A pull is a force-overwrite of instance state from the connected branch.
# Anything hand-edited on the instance is discarded.
#
# autoPublish: "all" republishes the affected workflows after pulling. Without
# it the pull updates the saved version and leaves the *published* version
# alone — so a rollback would look applied in the editor while the active
# version stays broken. The promotion pipeline in this repo
# (workflows/VjZ8UMkT85Bp2mZX.json) sends the same pair; keep them aligned.
#
set -euo pipefail

: "${N8N_BASE_URL:?N8N_BASE_URL is required}"
: "${N8N_API_KEY:?N8N_API_KEY is required}"

FORCE="${N8N_PULL_FORCE:-true}"
AUTOPUBLISH="${N8N_PULL_AUTOPUBLISH:-all}"

URL="${N8N_BASE_URL%/}/api/v1/source-control/pull"
BODY=$(printf '{"force": %s, "autoPublish": "%s"}' "$FORCE" "$AUTOPUBLISH")

resp=$(mktemp)
code=$(curl -sS -o "$resp" -w '%{http_code}' --max-time 120 \
  -X POST "$URL" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "$BODY" || echo 000)

case "$code" in
  200|201|204)
    echo "✓ pull complete on ${N8N_BASE_URL}  (force=$FORCE autoPublish=$AUTOPUBLISH)"
    head -c 2000 "$resp"; echo
    ;;
  400|422)
    echo "✗ $code — the instance rejected the request body." >&2
    cat "$resp" >&2; echo >&2
    echo "  Older n8n builds do not accept autoPublish. Re-run with" >&2
    echo "  N8N_PULL_AUTOPUBLISH= to omit it, then publish the workflow by hand." >&2
    exit 1
    ;;
  401|403)
    echo "✗ auth rejected ($code). Check N8N_API_KEY, and that the key's user has the" >&2
    echo "  admin/owner role — source control endpoints are owner-scoped." >&2
    exit 1
    ;;
  404)
    echo "✗ 404. Either the public API is disabled (N8N_PUBLIC_API_DISABLED) or this" >&2
    echo "  instance has no source control connection configured." >&2
    exit 1
    ;;
  409)
    echo "✗ 409 conflict — the instance has local changes blocking the pull." >&2
    cat "$resp" >&2; echo >&2
    echo "  Resolve in Settings → Source Control, or re-run with force." >&2
    exit 1
    ;;
  000)
    echo "✗ could not reach ${N8N_BASE_URL} (timeout / DNS / TLS)" >&2
    exit 1
    ;;
  *)
    echo "✗ pull failed with HTTP $code" >&2
    cat "$resp" >&2; echo >&2
    exit 1
    ;;
esac
