# resource "azurerm_firewall_nat_rule_collection" "postgres_dnat" {
#   name                = "grafana-postgres-dnat"
#   azure_firewall_name = azurerm_firewall.main.name
#   resource_group_name = azurerm_firewall.main.resource_group_name
#   priority            = 100
#   action              = "Dnat"

#   rule {
#     name                  = "postgres-access"
#     source_addresses      = ["*"]
#     destination_addresses = [azurerm_public_ip.firewall.ip_address]
#     destination_ports     = ["5432"]
#     protocols             = ["TCP"]
#     translated_address    = azurerm_postgresql_flexible_server.main.private_ip_address
#     translated_port       = "5432"
#   }
# }