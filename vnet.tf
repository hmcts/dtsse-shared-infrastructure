resource "azurerm_virtual_network" "db_vnet" {
  count               = var.env == "prod" ? 1 : 0
  name                = "${var.product}-vnet-${var.env}"
  location            = var.location
  resource_group_name = module.postgresql[0].resource_group_name
  address_space       = ["10.3.0.0/24"]
  tags                = var.common_tags
}

resource "azurerm_subnet" "db_subnet" {
  count                = var.env == "prod" ? 1 : 0
  name                 = "PostgreSQL-Subnet"
  resource_group_name  = module.postgresql[0].resource_group_name
  virtual_network_name = azurerm_virtual_network.db_vnet[0].name
  address_prefixes     = ["10.3.0.0/28"]

  delegation {
    name = "Microsoft.DBforPostgreSQL.flexibleServers"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  depends_on = [
    azurerm_virtual_network.db_vnet
  ]
}

resource "azurerm_subnet" "pls_subnet" {
  count                = var.env == "prod" ? 1 : 0
  name                 = "PrivateLink-Subnet"
  resource_group_name  = module.postgresql[0].resource_group_name
  virtual_network_name = azurerm_virtual_network.db_vnet[0].name
  address_prefixes     = ["10.3.0.16/28"]

  private_link_service_network_policies_enabled = false

  depends_on = [
    azurerm_virtual_network.db_vnet
  ]
}
