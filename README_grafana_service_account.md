# Grafana Service Account Automation

This adds a script + sample Azure DevOps pipeline to automate creation & rotation of a Grafana service account token for Terraform usage (sets `GRAFANA_AUTH`).

## Components

- `scripts/manage_grafana_service_account.sh` – Idempotent script:
  - Ensures service account (Grafana Admin role) exists
  - Deletes expired tokens
  - Re-uses an existing valid token or creates a new one (TTL default 90d)
  - Outputs token either:
    - As Azure DevOps secret variable `GRAFANA_AUTH` (default), or
    - Stores it in an Azure Key Vault secret

- `azure-pipelines.yml` – Example pipeline stage invoking the script via the AzureCLI task.

## Script Inputs (Environment Variables)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GRAFANA_INSTANCE_NAME` | Yes | – | Azure Managed Grafana instance name (e.g. `dtsse-grafana-aat-f6avdaarczcqftge`) |
| `SERVICE_ACCOUNT_NAME` | No | `dtsse-grafana-tf-admin` | Service account name to manage |
| `TOKEN_TTL` | No | `90d` | Lifetime passed to `az grafana service-account token create` |
| `OUTPUT_MODE` | No | `secretVariable` | `secretVariable` or `keyvault` |
| `KEYVAULT_NAME` | If `OUTPUT_MODE=keyvault` | – | Key Vault name to store secret |
| `TOKEN_SECRET_NAME` | No | `GRAFANA_AUTH` | Secret name in Key Vault |
| `ALLOW_MULTIPLE_ACTIVE_TOKENS` | No | `false` | If `false`, only one active token intended (new created only if we cannot recover existing value) |
| `DRY_RUN` | No | `false` | If `true`, logs actions without mutating state |

## Outputs

- If `OUTPUT_MODE=secretVariable`: Sets Azure DevOps secret variable `GRAFANA_AUTH`.
- If `OUTPUT_MODE=keyvault`: Writes/overwrites secret `TOKEN_SECRET_NAME` in the Key Vault.

## Usage Locally

Authenticate with Azure CLI (service principal or user) that has permissions on the Grafana instance and optionally the Key Vault.

```bash
export GRAFANA_INSTANCE_NAME=dtsse-grafana-aat-f6avdaarczcqftge
bash scripts/manage_grafana_service_account.sh
```

Key Vault mode:
```bash
export GRAFANA_INSTANCE_NAME=dtsse-grafana-aat-f6avdaarczcqftge
export OUTPUT_MODE=keyvault
export KEYVAULT_NAME=<kv-name>
bash scripts/manage_grafana_service_account.sh
```

Dry run:
```bash
DRY_RUN=true GRAFANA_INSTANCE_NAME=... bash scripts/manage_grafana_service_account.sh
```

## Azure DevOps Pipeline Notes

- The AzureCLI task sets `addSpnToEnvironment: true` so the service principal is used by the script.
- After the run, downstream Terraform tasks can read `$(GRAFANA_AUTH)` as the provider auth token.
- Ensure the service principal has at least `Grafana Admin` assignment if creating service accounts; typically Contributor on the Grafana resource is sufficient.

## Integration with Terraform

Configure the Grafana Terraform provider to read `GRAFANA_AUTH` environment variable.

Example snippet:
```hcl
provider "grafana" {
  url  = "https://${var.grafana_hostname}"
  auth = var.grafana_auth != "" ? var.grafana_auth : null
}
```
Then pass via environment variable mapping in the pipeline:

```yaml
- task: TerraformCLI@0
  env:
    GRAFANA_AUTH: $(GRAFANA_AUTH)
```

## Limitations / Notes

- Azure CLI only returns the token secret at creation time; if reusing an existing token and you didn't store it in Key Vault previously, a fresh token must be created.
- Token list fields differ between CLI versions; script uses a Python helper with `python-dateutil` (ship with azure image) to parse flexible field names. If `dateutil` isn't available, install via `pip install python-dateutil` before running.
- Revocation attempts both `revoke` and `delete` subcommands for compatibility.

## Future Enhancements

- Add optional max token age rotation prior to expiry.
- Add ShellCheck CI step.
- Add GitHub Actions variant.

---
Generated for ticket automation requirements.
