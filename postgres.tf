locals {
  component    = "dashboard"
  outbound_ips = try(azurerm_dashboard_grafana.dashboard-grafana[0].outbound_ip, [])
}

module "postgresql" {
  count = var.dashboard_count

  providers = {
    azurerm.postgres_network = azurerm.postgres_network
  }

  source = "git@github.com:hmcts/terraform-module-postgresql-flexible?ref=ad-group-object-id"
  env    = var.env

  name          = "dtsse-dashboard-flexdb"
  product       = var.product
  component     = local.component
  business_area = "cft" # sds or cft

  pgsql_databases = [
    {
      name : "dashboard"
    }
  ]

  pgsql_version             = "14"
  public_access             = var.pgsql_public_access
  pgsql_delegated_subnet_id = !var.pgsql_public_access ? azurerm_subnet.db_subnet[0].id : ""

  pgsql_firewall_rules = var.pgsql_public_access && length(var.private_link_resource) == 0 ? [
    {
      name             = "grafana00"
      start_ip_address = azurerm_dashboard_grafana.dashboard-grafana[0].outbound_ip[0]
      end_ip_address   = azurerm_dashboard_grafana.dashboard-grafana[0].outbound_ip[0]
    },
    {
      name             = "grafana01"
      start_ip_address = azurerm_dashboard_grafana.dashboard-grafana[0].outbound_ip[1]
      end_ip_address   = azurerm_dashboard_grafana.dashboard-grafana[0].outbound_ip[1]
    },
    {
      name             = "grafana1000"
      start_ip_address = azurerm_dashboard_grafana.dashboard-grafana10[0].outbound_ip[0]
      end_ip_address   = azurerm_dashboard_grafana.dashboard-grafana10[0].outbound_ip[0]
    },
    {
      name             = "grafana1001"
      start_ip_address = azurerm_dashboard_grafana.dashboard-grafana10[0].outbound_ip[1]
      end_ip_address   = azurerm_dashboard_grafana.dashboard-grafana10[0].outbound_ip[1]
    },
  ] : []
  admin_user_object_id = var.jenkins_AAD_objectId

  common_tags = var.common_tags

  depends_on = [
    azurerm_dashboard_grafana.dashboard-grafana,
    azurerm_dashboard_grafana.dashboard-grafana10
  ]
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  count     = var.dashboard_count
  name      = "azure.extensions"
  server_id = module.postgresql[0].instance_id
  value     = "hypopg,plpgsql,pg_stat_statements,pg_buffercache"
}

resource "azurerm_key_vault_secret" "DB-URL" {
  count        = var.dashboard_count
  name         = "db-url"
  value        = "postgresql://${module.postgresql[0].username}:${module.postgresql[0].password}@${module.postgresql[0].fqdn}:5432/dashboard?sslmode=require"
  key_vault_id = module.key-vault.key_vault_id
}
