#!/usr/bin/env bash
# Purpose: Manage Azure Managed Grafana service account and token.
# - Ensure service account exists with Admin role.
# - Revoke expired tokens.
# - Reuse valid token if possible; create new if needed (configurable TTL).
# - Store token name and value in Key Vault.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_PREFIX="[grafana-sa]"

: "${GRAFANA_INSTANCE_NAME:?GRAFANA_INSTANCE_NAME required}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-dtsse-grafana-tf-admin}"
TOKEN_TTL="${TOKEN_TTL:-90d}"
KEYVAULT_NAME="${KEYVAULT_NAME:-}"
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-grafana-auth}"
TOKEN_NAME_SECRET_NAME="${TOKEN_NAME_SECRET_NAME:-grafana-auth-name}"
ROTATE="${ROTATE:-false}" # Force new token and revoke others
DEBUG="${DEBUG:-false}"

# Helpers
log() { echo "${LOG_PREFIX} $*" >&2; }
debug() { [[ "$DEBUG" == "true" ]] && echo "${LOG_PREFIX} DEBUG: $*" >&2; }
error() { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

require_cli() { command -v az >/dev/null || error "Azure CLI (az) required"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
$SCRIPT_NAME - Manage Grafana service account and token

Required: GRAFANA_INSTANCE_NAME

Optional:
  SERVICE_ACCOUNT_NAME    (default: $SERVICE_ACCOUNT_NAME)
  TOKEN_TTL               (default: $TOKEN_TTL)
  KEYVAULT_NAME           (required)
  TOKEN_SECRET_NAME       (default: $TOKEN_SECRET_NAME)
  TOKEN_NAME_SECRET_NAME  (default: $TOKEN_NAME_SECRET_NAME)
  ROTATE                  (default: $ROTATE)
  DEBUG                   (default: $DEBUG)
EOF
  exit 0
fi

require_cli

if [[ -z "$KEYVAULT_NAME" ]]; then
  error "KEYVAULT_NAME required"
fi


for secret in "$TOKEN_SECRET_NAME" "$TOKEN_NAME_SECRET_NAME"; do
  [[ "$secret" =~ ^[A-Za-z0-9-]+$ ]] || error "Invalid secret name '$secret' (alphanumerics & - only)"
done

az account show >/dev/null || error "Azure CLI login required (use service principal)"

# Service Account Management
ensure_service_account() {
  log "Checking service account '$SERVICE_ACCOUNT_NAME' on '$GRAFANA_INSTANCE_NAME'"
  local exists
  exists=$(az grafana service-account list -n "$GRAFANA_INSTANCE_NAME" --query "[?name=='$SERVICE_ACCOUNT_NAME'] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "$exists" == "0" ]]; then
    log "Creating service account with Admin role"
    az grafana service-account create -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --role Admin >/dev/null
  else
    log "Service account exists"
    local current_role
    current_role=$(az grafana service-account show -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" -o json 2>/dev/null | jq -r '.role // ""')
    if [[ "$current_role" != "Admin" ]]; then
      log "Updating service account role to Admin"
      az grafana service-account update -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --role Admin >/dev/null
    fi
  fi
}

# Token Management
get_tokens_json() {
  az grafana service-account token list -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" -o json 2>/dev/null || echo '[]'
}

normalize_tokens() {
  jq -r '.[] | [.id // "", .name // "unknown", .expiration // "", if .hasExpired then "true" else "false" end] | join("|")' < <(get_tokens_json)
}

revoke_token() {
  local name="$1"
  [[ -z "$name" ]] && return
  log "Revoking token '$name'"
  az grafana service-account token delete -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --token "$name" >/dev/null 2>&1
}

create_token() {
  local name="$SERVICE_ACCOUNT_NAME-$(date -u +%Y%m%d%H%M%S)"
  log "Creating token '$name' (TTL: $TOKEN_TTL)"
  local output key
  output=$(az grafana service-account token create -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --token "$name" --time-to-live "$TOKEN_TTL" -o json)
  key=$(echo "$output" | jq -r '.key // .token // .value // empty')
  [[ -z "$key" ]] && error "Failed to create token or extract key"
  echo "$key" "$name"
}

# Remove expired tokens from Grafana
cleanup_expired() {
  local tokens
  tokens=$(normalize_tokens)
  while IFS='|' read -r id name exp expired; do
    [[ -z "$name" ]] && continue
    [[ "$expired" == "true" ]] || continue
    revoke_token "$name"
  done <<< "$tokens"
}

# Prune all active tokens except given name
prune_all_except() {
  local keep_name="$1"
  local tokens
  tokens=$(normalize_tokens)
  while IFS='|' read -r id name exp expired; do
    [[ -z "$name" ]] && continue
    [[ "$expired" == "true" ]] && continue
    [[ "$name" == "$keep_name" ]] && continue
    revoke_token "$name"
  done <<< "$tokens"
}

select_or_create_token() {
  cleanup_expired

  local tokens raw active_names active_count
  tokens=$(get_tokens_json)
  debug "Raw tokens JSON length: ${#tokens}"
  raw=$(echo "$tokens" | jq -r '.[] | [.name, .hasExpired // false] | @tsv' 2>/dev/null || true)
  debug "Raw token rows (name\texpired):${raw:+\n}$raw"

  # Build active names list directly from JSON to avoid formatting surprises
  active_names=$(echo "$tokens" | jq -r '.[] | select((.hasExpired|not) and (.isRevoked|not)) | .name' 2>/dev/null || true)
  # Normalize list into array counting only non-empty lines
  active_count=$(echo "$active_names" | grep -c '.' || true)
  debug "Active token names (Grafana):${active_names:+\n}$active_names"
  debug "Active token count: $active_count (rotate=$ROTATE)"

  # 2. Rotation forced
  if [[ "$ROTATE" == "true" ]]; then
    log "Rotation forced; creating fresh token"
    read -r new_value new_name < <(create_token)
    prune_all_except "$new_name"
    echo "$new_value" "$new_name" CREATED
    return
  fi

  # 3. No active tokens -> create
  if [[ $active_count -eq 0 ]]; then
    log "No active Grafana tokens; creating new"
    read -r new_value new_name < <(create_token)
    echo "$new_value" "$new_name" CREATED
    return
  fi

  # 4. Exactly one active token: attempt KV reuse
  if [[ $active_count -eq 1 ]]; then
    local sole_name stored_name stored_value
    sole_name=$(echo "$active_names" | head -1)
    stored_name=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
    stored_value=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
    debug "KV lookup deferred: stored_name='$stored_name' value_present=$([[ -n "$stored_value" ]] && echo yes || echo no)"
    if [[ -n "$stored_value" && "$stored_name" == "$sole_name" ]]; then
      log "Reusing sole active token '$sole_name'"
      prune_all_except "$sole_name"
      echo "$stored_value" "$sole_name" REUSED
      return
    else
      log "Sole active token '$sole_name' has no matching value in KV; rotating"
      prune_all_except "__none__" 2>/dev/null || true
      read -r new_value new_name < <(create_token)
      prune_all_except "$new_name"
      echo "$new_value" "$new_name" CREATED
      return
    fi
  fi

  # 5. Multiple active tokens -> consolidate
  log "Multiple active tokens detected; consolidating"
  prune_all_except "__none__" 2>/dev/null || true
  read -r new_value new_name < <(create_token)
  prune_all_except "$new_name"
  echo "$new_value" "$new_name" CREATED
}

# Main
ensure_service_account

read -r TOKEN_VALUE NEW_TOKEN_NAME TOKEN_STATUS < <(select_or_create_token)

if [[ -z "$TOKEN_VALUE" ]]; then
  error "No token value obtained"
fi

current_kv_value=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
current_kv_name=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --query value -o tsv 2>/dev/null || true)

if [[ "$TOKEN_STATUS" == "CREATED" || "$current_kv_value" != "$TOKEN_VALUE" ]]; then
  log "Updating Key Vault secret '$TOKEN_SECRET_NAME' (reason: $([[ "$TOKEN_STATUS" == CREATED ]] && echo created || echo value-changed))"
  debug "KV update: '$TOKEN_SECRET_NAME' old_len=${#current_kv_value} new_len=${#TOKEN_VALUE}"
  az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --value "$TOKEN_VALUE" >/dev/null
else
  debug "Skip KV update: '$TOKEN_SECRET_NAME' unchanged (status=$TOKEN_STATUS)"
fi

if [[ -n "$NEW_TOKEN_NAME" ]]; then
  if [[ "$TOKEN_STATUS" == "CREATED" || "$current_kv_name" != "$NEW_TOKEN_NAME" ]]; then
    log "Updating Key Vault secret '$TOKEN_NAME_SECRET_NAME' (reason: $([[ "$TOKEN_STATUS" == CREATED ]] && echo created || echo name-changed))"
    debug "KV update: '$TOKEN_NAME_SECRET_NAME' old='$current_kv_name' new='$NEW_TOKEN_NAME'"
    az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --value "$NEW_TOKEN_NAME" >/dev/null
  else
    debug "Skip KV update: '$TOKEN_NAME_SECRET_NAME' unchanged (status=$TOKEN_STATUS)"
  fi
fi

log "Completed"
