#!/usr/bin/env bash
# Purpose: Manage Azure Managed Grafana service account and token.
# - Ensure service account exists with Admin role.
# - Revoke expired tokens.
# - Reuse valid token if possible; create new if needed (configurable TTL).
# - Output token as Azure DevOps secret variable or store in Key Vault.
# - Designed for AzureCLI task with service principal auth.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_PREFIX="[grafana-sa]"

# Configuration Inputs (required/optional env vars)
: "${GRAFANA_INSTANCE_NAME:?GRAFANA_INSTANCE_NAME required (e.g., dtsse-grafana-aat-f6avdaarczcqftge)}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-dtsse-grafana-tf-admin}"
TOKEN_TTL="${TOKEN_TTL:-90d}"
OUTPUT_MODE="${OUTPUT_MODE:-secretVariable}"  # secretVariable | keyvault
KEYVAULT_NAME="${KEYVAULT_NAME:-}"           # Required if OUTPUT_MODE=keyvault
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-grafana-auth}"  # KV secret name (alphanumerics & - only)
TOKEN_NAME_SECRET_NAME="${TOKEN_NAME_SECRET_NAME:-grafana-auth-name}"
ALLOW_MULTIPLE_ACTIVE_TOKENS="${ALLOW_MULTIPLE_ACTIVE_TOKENS:-false}"
DRY_RUN="${DRY_RUN:-false}"
ROTATE="${ROTATE:-false}"                    # Force new token and prune others
CLEANUP_ALL_OTHERS="${CLEANUP_ALL_OTHERS:-true}"  # Revoke extras when reusing
REUSE_ONLY="${REUSE_ONLY:-true}"             # Never create if any active exists (unless ROTATE=true)
CLEANUP_ONLY="${CLEANUP_ONLY:-false}"        # Prune to one active token and exit
KEEP_TOKEN_NAME="${KEEP_TOKEN_NAME:-}"       # Specific token name to keep during cleanup
DEBUG="${DEBUG:-false}"
POST_CREATE_SLEEP="${POST_CREATE_SLEEP:-2}"  # Wait for Azure to reflect changes
NEW_TOKEN_NAME=""                              # Always set to avoid unbound variable
TOKEN_VALUE=""                                 # Global token value (set by logic)
ALWAYS_WRITE_ON_REUSE="${ALWAYS_WRITE_ON_REUSE:-false}" # If true, still write KV secrets even when just reusing
FIX_NAME_MISMATCH="${FIX_NAME_MISMATCH:-true}"           # If true, update name secret when value exists but stored name not active
STALE_TOKEN_RECREATE="${STALE_TOKEN_RECREATE:-true}"     # If true, if KV has value but no active tokens, create new one (stale secret)

# Helpers
log() { echo "${LOG_PREFIX} $*" >&2; }
debug() { [[ "$DEBUG" == "true" ]] && echo "${LOG_PREFIX} DEBUG: $*" >&2; }
error() { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

require_cli() { command -v az >/dev/null || error "Azure CLI (az) required"; }

usage() {
  cat <<EOF
$SCRIPT_NAME - Manage Grafana service account and token

Required: GRAFANA_INSTANCE_NAME

Optional:
  SERVICE_ACCOUNT_NAME    (default: $SERVICE_ACCOUNT_NAME)
  TOKEN_TTL               (default: $TOKEN_TTL)
  OUTPUT_MODE             (default: $OUTPUT_MODE)
  KEYVAULT_NAME           (required for keyvault mode)
  TOKEN_SECRET_NAME       (default: $TOKEN_SECRET_NAME)
  TOKEN_NAME_SECRET_NAME  (default: $TOKEN_NAME_SECRET_NAME)
  ALLOW_MULTIPLE_ACTIVE_TOKENS (default: $ALLOW_MULTIPLE_ACTIVE_TOKENS)
  DRY_RUN                 (default: $DRY_RUN)
  ROTATE                  (default: $ROTATE)
  CLEANUP_ALL_OTHERS      (default: $CLEANUP_ALL_OTHERS)
  REUSE_ONLY              (default: $REUSE_ONLY)
  CLEANUP_ONLY            (default: $CLEANUP_ONLY)
  KEEP_TOKEN_NAME         (for CLEANUP_ONLY)
  ALWAYS_WRITE_ON_REUSE   (default: $ALWAYS_WRITE_ON_REUSE) write KV secrets even if no new token
  FIX_NAME_MISMATCH       (default: $FIX_NAME_MISMATCH) auto-fix name secret if it doesn't match active token
  STALE_TOKEN_RECREATE    (default: $STALE_TOKEN_RECREATE) recreate if KV has value but Grafana has none
  DEBUG                   (default: $DEBUG)

Outputs:
  - secretVariable: Sets GRAFANA_AUTH as secret pipeline var
  - keyvault: Stores in specified Key Vault
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

require_cli

if [[ "$OUTPUT_MODE" == "keyvault" && -z "$KEYVAULT_NAME" ]]; then
  error "KEYVAULT_NAME required for keyvault mode"
fi

if [[ "$OUTPUT_MODE" == "keyvault" ]]; then
  for secret in "$TOKEN_SECRET_NAME" "$TOKEN_NAME_SECRET_NAME"; do
    [[ "$secret" =~ ^[A-Za-z0-9-]+$ ]] || error "Invalid secret name '$secret' (alphanumerics & - only)"
  done
fi

az account show >/dev/null || error "Azure CLI login required (use service principal)"

# Service Account Management
ensure_service_account() {
  log "Checking service account '$SERVICE_ACCOUNT_NAME' on '$GRAFANA_INSTANCE_NAME'"
  local exists
  exists=$(az grafana service-account list -n "$GRAFANA_INSTANCE_NAME" --query "[?name=='$SERVICE_ACCOUNT_NAME'] | length(@)" -o tsv 2>/dev/null || echo 0)
  if [[ "$exists" == "0" ]]; then
    log "Creating service account with Admin role"
    [[ "$DRY_RUN" == "true" ]] && { log "DRY_RUN: Skipping create"; return; }
    az grafana service-account create -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --role Admin >/dev/null
  else
    log "Service account exists"
  fi
}

# Token Management
get_tokens_json() {
  az grafana service-account token list -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" -o json 2>/dev/null || echo '[]'
}

normalize_tokens() {
  python3 -c '
import json, sys, datetime
data = json.loads(sys.stdin.read() or "[]")
now = datetime.datetime.now(datetime.timezone.utc)
for t in data:
    tid = str(t.get("id", ""))
    name = t.get("name", "unknown")
    exp_str = t.get("expiresAt") or t.get("expiration") or t.get("expiry") or ""
    has_expired = t.get("hasExpired", False) or t.get("isRevoked", False)
    try:
        dt = datetime.datetime.fromisoformat(exp_str.replace("Z", "+00:00")) if exp_str else None
    except ValueError:
        dt = None
    expired = "true" if has_expired or (dt and dt < now) else "false"
    exp_iso = dt.isoformat().replace("+00:00", "Z") if dt else ""
    print("|".join([tid, name, exp_iso, expired]))
' < <(get_tokens_json)
}

revoke_token() {
  local name="$1" id="$2"
  [[ -z "$name" ]] && return
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN: Would revoke token '$name' (id: $id)"
    return
  fi
  az grafana service-account token delete -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --token "$name" >/dev/null 2>&1 || \
    log "Failed to revoke token '$name' (id: $id)"
}

create_token() {
  local name="$SERVICE_ACCOUNT_NAME-$(date -u +%Y%m%d%H%M%S)"
  NEW_TOKEN_NAME="$name"
  log "Creating token '$name' (TTL: $TOKEN_TTL)"
  if [[ "$DRY_RUN" == "true" ]]; then
    TOKEN_VALUE="SIMULATED_TOKEN"
    return
  fi
  local key output
  key=$(az grafana service-account token create -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --token "$name" --time-to-live "$TOKEN_TTL" --query key -o tsv 2>/dev/null || true)
  if [[ -z "$key" ]]; then
    output=$(az grafana service-account token create -n "$GRAFANA_INSTANCE_NAME" --service-account "$SERVICE_ACCOUNT_NAME" --token "$name" --time-to-live "$TOKEN_TTL" -o json 2>&1 || true)
    debug "Full create output (length): ${#output}"
    key=$(echo "$output" | python3 -c '
import json, sys, re
data = sys.stdin.read()
match = re.search(r"{.*}", data, re.DOTALL)
if match:
    try:
        j = json.loads(match.group(0))
        print(j.get("key") or j.get("token") or j.get("value") or "")
    except:
        pass
' || true)
  fi
  [[ -z "$key" ]] && error "Failed to create token or extract key"
  debug "Extracted key length: ${#key}"
  TOKEN_VALUE="$key"
}

prune_tokens() {
  local keep_name="$1"
  sleep "$POST_CREATE_SLEEP"
  local tokens
  tokens=$(normalize_tokens)
  if [[ -z "$keep_name" ]]; then
    keep_name=$(echo "$tokens" | awk -F'|' '$4=="false" {print $2 "|" $3}' | sort -t'|' -k2r | head -n1 | cut -d'|' -f1)
  fi
  [[ -z "$keep_name" ]] && return
  # Count active first; skip noisy log if already single
  local pre_active_count
  pre_active_count=$(echo "$tokens" | awk -F'|' '$4=="false"{print 1}' | wc -l || echo 0)
  if (( pre_active_count <= 1 )); then
    debug "Prune skipped (already single token '$keep_name')"
    return
  fi
  log "Pruning tokens; keeping '$keep_name'"
  local attempts=0 max_attempts=5
  while ((attempts < max_attempts)); do
    attempts=$((attempts + 1))
    tokens=$(normalize_tokens)
    local active_count=0 changed=false
    while IFS='|' read -r id name exp expired; do
      [[ "$expired" == "true" || -z "$name" ]] && continue
      active_count=$((active_count + 1))
      if [[ "$name" != "$keep_name" ]]; then
        revoke_token "$name" "$id"
        changed=true
      fi
    done <<< "$tokens"
    ((active_count <= 1)) && break
    [[ "$changed" == "false" ]] && break
    sleep 1
  done
  ((active_count > 1)) && log "Warning: Could not prune to single token (remaining: $active_count)"
}

cleanup_expired() {
  local tokens
  tokens=$(normalize_tokens)
  while IFS='|' read -r id name exp expired; do
    [[ "$expired" == "false" || -z "$name" ]] && continue
    log "Revoking expired token '$name' (exp: $exp)"
    revoke_token "$name" "$id"
  done <<< "$tokens"
}

select_or_create_token() {
  local stored_value="" stored_name="" create_new=false
  NEW_TOKEN_NAME=""
  if [[ "$OUTPUT_MODE" == "keyvault" ]]; then
    stored_value=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
    stored_name=$(az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --query value -o tsv 2>/dev/null || true)
    debug "Stored: value exists? $([[ -n "$stored_value" ]] && echo yes || echo no); name: '$stored_name'"
  fi

  cleanup_expired

  local tokens active_count active_name
  tokens=$(normalize_tokens)
  active_count=$(echo "$tokens" | awk -F'|' '$4=="false" {print 1}' | wc -l || echo 0)
  debug "Active tokens: $active_count"
  debug "Decision inputs: REUSE_ONLY=$REUSE_ONLY ROTATE=$ROTATE ALLOW_MULTIPLE_ACTIVE_TOKENS=$ALLOW_MULTIPLE_ACTIVE_TOKENS CLEANUP_ALL_OTHERS=$CLEANUP_ALL_OTHERS"

  # Stale token detection: KV has a value but Grafana shows zero active tokens
  if [[ "$OUTPUT_MODE" == "keyvault" && -n "$stored_value" && $active_count -eq 0 && "$STALE_TOKEN_RECREATE" == "true" ]]; then
    log "Detected stale token secret (no active tokens in Grafana, but value exists). Forcing new token creation."
    create_new=true
  fi

  # If value present but name missing, attempt inference (even with >1 active choose newest) and store name without creating new token
  if [[ "$OUTPUT_MODE" == "keyvault" && -n "$stored_value" && -z "$stored_name" && $active_count -gt 0 ]]; then
    stored_name=$(echo "$tokens" | awk -F'|' '$4=="false" {print $2"|"$3}' | sort -t'|' -k2,2r | head -1 | cut -d'|' -f1)
    if [[ -n "$stored_name" ]]; then
      log "Inferred missing token name as '$stored_name' from existing active tokens"
      if [[ "$DRY_RUN" == "false" ]]; then
        az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --value "$stored_name" >/dev/null || log "Failed to store inferred name"
      fi
    fi
  fi

  if ((active_count > 0)); then
    if [[ "$ALLOW_MULTIPLE_ACTIVE_TOKENS" == "false" && "$CLEANUP_ALL_OTHERS" == "true" ]]; then
      prune_tokens "$stored_name"  # Now prunes only if >1
      tokens=$(normalize_tokens)  # Refresh
      active_count=$(echo "$tokens" | awk -F'|' '$4=="false" {print 1}' | wc -l || echo 0)
    fi
    # Auto-fix name mismatch: stored name present but not active while there IS exactly one active token and we have a stored value
    if [[ "$OUTPUT_MODE" == "keyvault" && "$FIX_NAME_MISMATCH" == "true" && -n "$stored_value" && -n "$stored_name" ]]; then
      if ! echo "$tokens" | awk -F'|' -v n="$stored_name" '$2==n && $4=="false"{f=1}END{exit f?0:1}'; then
        # Determine a currently active token name (newest)
        current_active_name=$(echo "$tokens" | awk -F'|' '$4=="false"{print $2"|"$3}' | sort -t'|' -k2,2r | head -1 | cut -d'|' -f1)
        if [[ -n "$current_active_name" ]]; then
          log "Detected name mismatch: stored '$stored_name' not active. Updating name secret to '$current_active_name'"
          if [[ "$DRY_RUN" == "false" ]]; then
            az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --value "$current_active_name" >/dev/null || log "Failed to update mismatched name secret"
          fi
          stored_name="$current_active_name"
        fi
      fi
    fi
  if [[ "$REUSE_ONLY" == "true" && "$ROTATE" != "true" ]]; then
      log "Decision: REUSE_ONLY enforced and active tokens present (rotation not requested)"
      if [[ "$OUTPUT_MODE" == "keyvault" && -n "$stored_value" ]]; then
        if [[ -z "$stored_name" ]]; then
          log "Name still missing after inference; proceeding with stored value only (no creation)."
      TOKEN_VALUE="$stored_value"; return
        fi
        if echo "$tokens" | awk -F'|' -v n="$stored_name" '$2==n && $4=="false"{f=1}END{exit f?0:1}'; then
          log "Reusing token '$stored_name'"
      TOKEN_VALUE="$stored_value"; return
        else
          log "Stored name '$stored_name' not active; falling back to first active token value reuse (name not trackable)."
      TOKEN_VALUE="$stored_value"; return
        fi
      else
        error "REUSE_ONLY active but no stored token value available to output. Run once with ROTATE=true to seed."
      fi
    fi
    if [[ "$ROTATE" != "true" && "$OUTPUT_MODE" == "keyvault" && -n "$stored_value" && -n "$stored_name" ]] && echo "$tokens" | grep -q -E "^[^|]*\|$stored_name\|[^|]*\|false$"; then
      log "Reusing stored token '$stored_name' (no rotation)"
    TOKEN_VALUE="$stored_value"
      return
    fi
  fi

  # Determine if we should create
  if [[ "$create_new" == "true" ]]; then
    debug "Creation forced earlier (stale or explicit condition)"
  else
    if [[ "$REUSE_ONLY" == "true" && ((active_count > 0)) && "$ROTATE" != "true" ]]; then
      create_new=false
    elif [[ "$ROTATE" == "true" || ((active_count == 0)) ]]; then
      create_new=true
    else
      create_new=false
    fi
  fi
  debug "Final decision: create_new=$create_new active_count=$active_count stale=$([[ $active_count -eq 0 && -n $stored_value ]] && echo yes || echo no)"

  if [[ "$create_new" == "false" ]]; then
    log "Skipping creation (decision matrix determined reuse or no-op)."
    NEW_TOKEN_NAME=""
    if [[ "$OUTPUT_MODE" == "keyvault" && -n "$stored_value" ]]; then
      TOKEN_VALUE="$stored_value"; return
    fi
    return
  fi

  create_token
  if [[ "$ALLOW_MULTIPLE_ACTIVE_TOKENS" == "false" ]]; then
    prune_tokens "$NEW_TOKEN_NAME"
  fi
  return
}

# Main
ensure_service_account

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  log "CLEANUP_ONLY: Pruning tokens"
  cleanup_expired
  if [[ "$ALLOW_MULTIPLE_ACTIVE_TOKENS" == "false" ]]; then
    prune_tokens "$KEEP_TOKEN_NAME"
  fi
  log "Cleanup complete"
  exit 0
fi

select_or_create_token || error "Failed to get/create token"
debug "Post-select: NEW_TOKEN_NAME='${NEW_TOKEN_NAME}' token_length=${#TOKEN_VALUE}"

if [[ -z "$TOKEN_VALUE" ]]; then
  error "No token value obtained"
fi

# Output
if [[ "$OUTPUT_MODE" == "keyvault" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN: Would store in Key Vault '$KEYVAULT_NAME'"
  else
    if [[ -n "${NEW_TOKEN_NAME:-}" ]]; then
      log "Storing NEW token + name in Key Vault '$KEYVAULT_NAME'"
      az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --value "$TOKEN_VALUE" >/dev/null
      az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_NAME_SECRET_NAME" --value "$NEW_TOKEN_NAME" >/dev/null
      debug "Key Vault updated with new token (value length: ${#TOKEN_VALUE}) and name '$NEW_TOKEN_NAME'"
    else
      # Reuse path
      if [[ "$ALWAYS_WRITE_ON_REUSE" == "true" ]]; then
        log "Reusing token; ALWAYS_WRITE_ON_REUSE=true -> updating value only"
        az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$TOKEN_SECRET_NAME" --value "$TOKEN_VALUE" >/dev/null
        debug "Key Vault value refreshed (reuse path) length: ${#TOKEN_VALUE}"
      else
        log "Reusing token; skipping Key Vault write (no new token)."
        debug "Reuse path: no KV write (length: ${#TOKEN_VALUE})"
      fi
    fi
  fi
else
  echo "##vso[task.setvariable variable=GRAFANA_AUTH;isSecret=true]$TOKEN_VALUE"
  log "Set GRAFANA_AUTH secret variable"
fi

log "Completed"