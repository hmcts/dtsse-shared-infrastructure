moved {
  from = azurerm_dashboard_grafana.dashboard-grafana10
  to   = azurerm_dashboard_grafana.main
}

resource "azurerm_dashboard_grafana" "main" {
  count                             = var.dashboard_count
  name                              = "${var.product}-grafana10-${var.env}"
  resource_group_name               = azurerm_resource_group.rg.name
  location                          = var.location
  grafana_major_version             = var.grafana_major_version
  api_key_enabled                   = var.api_key_enabled
  zone_redundancy_enabled           = var.zone_redundancy_enabled
  deterministic_outbound_ip_enabled = true
  public_network_access_enabled     = var.public_network_access_enabled

  identity {
    type = "SystemAssigned"
  }

  tags = var.common_tags
}

data "azuread_group" "viewers" {
  display_name = "SSO Dynatrace HMCTS Access"
}

resource "azurerm_role_assignment" "viewers" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Viewer"
  principal_id         = data.azuread_group.viewers.object_id
}

data "azuread_group" "more_viewers" {
  display_name = "GeoBlocking - Restricted Users"
}

resource "azurerm_role_assignment" "more_viewers" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Viewer"
  principal_id         = data.azuread_group.more_viewers.object_id
}

data "azuread_group" "dts_se_grafana_readers" {
  display_name = "DTS SE - Grafana Readers"
}

resource "azurerm_role_assignment" "readers" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Viewer"
  principal_id         = data.azuread_group.dts_se_grafana_readers.object_id
}

data "azuread_group" "editors" {
  display_name = "DTS CFT Developers"
}

resource "azurerm_role_assignment" "editors" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Editor"
  principal_id         = data.azuread_group.editors.object_id
}

data "azuread_group" "admins" {
  display_name = "DTS CFT Software Engineering"
}

resource "azurerm_role_assignment" "admin" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azuread_group.admins.object_id
}

data "azuread_group" "platops" {
  display_name     = "DTS Platform Operations"
  security_enabled = true
}

resource "azurerm_role_assignment" "platops" {
  count                = var.dashboard_count
  scope                = azurerm_dashboard_grafana.main[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azuread_group.platops.object_id
}

resource "azurerm_role_assignment" "app_insights_dcd_cnp_prod_access" {
  count                = var.dashboard_count
  scope                = "/subscriptions/8999dec3-0104-4a27-94ee-6588559729d1"
  role_definition_name = "Reader"
  principal_id         = azurerm_dashboard_grafana.main[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "app_insights_dcd_cnp_aat_access" {
  count                = var.dashboard_count
  scope                = "/subscriptions/1c4f0704-a29e-403d-b719-b90c34ef14c9"
  role_definition_name = "Reader"
  principal_id         = azurerm_dashboard_grafana.main[0].identity[0].principal_id
}
