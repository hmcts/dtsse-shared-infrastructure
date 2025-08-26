#!/usr/bin/env bash
# Quick validation of Managed Grafana service account token stored in Key Vault (or env)
# Checks:
#  1. Endpoint reachable (/api/health)
#  2. Auth works (/api/org returns 200)
#  3. (Optional) Service account tokens list if ADMIN_CHECK=true
# Exit codes:
#  0 success, 1 missing prereq, 2 endpoint fail, 3 auth fail, 4 admin scope fail
set -euo pipefail

: "${GRAFANA_INSTANCE_NAME:?Set GRAFANA_INSTANCE_NAME}"  # e.g. dtsse-grafana-aat
GRAFANA_RESOURCE_GROUP="${GRAFANA_RESOURCE_GROUP:-}"     # Optional explicit RG; if unset rely on 'az grafana show -n'
KEYVAULT_NAME="${KEYVAULT_NAME:-}"            # Required if using Key Vault token retrieval
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-grafana-auth}"
TOKEN_NAME_SECRET_NAME="${TOKEN_NAME_SECRET_NAME:-grafana-auth-name}"
ADMIN_CHECK="${ADMIN_CHECK:-false}"           # If true, attempt /api/serviceaccounts
DEBUG="${DEBUG:-false}"
TOKEN_VALUE="${TOKEN_VALUE:-}"                # Allow direct injection (overrides KV)

log(){ echo "[grafana-validate] $*" >&2; }
debug(){ [[ "$DEBUG" == "true" ]] && echo "[grafana-validate] DEBUG: $*" >&2; }
err(){ echo "[grafana-validate] ERROR: $*" >&2; exit 1; }

command -v az >/dev/null || err "Azure CLI required"
command -v curl >/dev/null || err "curl required"

# Resolve endpoint
if [[ -n "$GRAFANA_RESOURCE_GROUP" ]]; then
  ENDPOINT=$(az grafana show -n "$GRAFANA_INSTANCE_NAME" -g "$GRAFANA_RESOURCE_GROUP" --query properties.endpoint -o tsv 2>/dev/null || true)
else
  ENDPOINT=$(az grafana show -n "$GRAFANA_INSTANCE_NAME" --query properties.endpoint -o tsv 2>/dev/null || true)
fi
[[ -z "$ENDPOINT" ]] && err "Failed to resolve Grafana endpoint"
ENDPOINT=${ENDPOINT%/}

debug "Endpoint: $ENDPOINT"

# Fetch token if not supplied
if [[ -z "$TOKEN_VALUE" ]]; then
  if [[ -n "$KEYVAULT_NAME" ]]; then
    TOKEN_VALUE=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
    [[ -z "$TOKEN_VALUE" ]] && err "Token secret '$TOKEN_SECRET_NAME' missing in KV '$KEYVAULT_NAME'"
  else
    err "TOKEN_VALUE not provided and KEYVAULT_NAME unset"
  fi
fi
TOKEN_NAME=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --query value -o tsv 2>/dev/null || true || true)
[[ -n "$TOKEN_NAME" ]] && debug "Token name (KV): $TOKEN_NAME"

auth_hdr=( -H "Authorization: Bearer $TOKEN_VALUE" )

# 1. Health (some Grafana endpoints may require auth; attempt unauth then auth)
code=$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/api/health" || true)
if [[ "$code" != "200" ]]; then
  debug "Unauth health returned $code; retrying with auth header"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${auth_hdr[@]}" "$ENDPOINT/api/health" || true)
fi
[[ "$code" != "200" ]] && { log "Health check failed HTTP $code"; exit 2; }
log "Health OK (200)"

# 2. Org
code=$(curl -s -o /dev/null -w '%{http_code}' "${auth_hdr[@]}" "$ENDPOINT/api/org" || true)
[[ "$code" != "200" ]] && { log "Auth failed (/api/org) HTTP $code"; exit 3; }
log "Auth OK (/api/org 200)"

# 3. Optional admin scope
if [[ "$ADMIN_CHECK" == "true" ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "${auth_hdr[@]}" "$ENDPOINT/api/serviceaccounts" || true)
  if [[ "$code" != "200" ]]; then
    log "Admin scope test failed (/api/serviceaccounts) HTTP $code"; exit 4
  fi
  log "Admin scope OK (/api/serviceaccounts 200)"
fi

log "Validation successful"
