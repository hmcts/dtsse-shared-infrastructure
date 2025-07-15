data "azurerm_subnet" "pls" {
  count                = var.env == "prod" ? 1 : 0
  name                 = "private-endpoints"
  resource_group_name  = "cft-${var.env}-network-rg"
  virtual_network_name = "cft-${var.env}-vnet"

  provider = azurerm.postgres_network
}
