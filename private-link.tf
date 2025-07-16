resource "azurerm_network_interface" "nic" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  name                = "${each.value.name}-${var.env}"
  location            = var.location
  resource_group_name = module.postgresql[0].resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.pls_subnet[0].id
    private_ip_address_allocation = "Dynamic"
  }
  tags = var.common_tags

  depends_on = [
    module.postgresql
  ]

}

resource "azurerm_lb" "pls" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  location            = var.location
  name                = format("%s-%s-lb", each.value.name, var.env)
  resource_group_name = module.postgresql[0].resource_group_name
  sku                 = "Standard"
  frontend_ip_configuration {
    name                          = "${each.value.name}-lbfe-1"
    zones                         = ["1", "2", "3"]
    subnet_id                     = azurerm_subnet.pls_subnet[0].id
    private_ip_address_allocation = "Dynamic"
  }
  tags = var.common_tags
}

resource "azurerm_lb_backend_address_pool" "pls" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  loadbalancer_id = azurerm_lb.pls[each.value.name].id
  name            = "grafana-backend-pool"
  depends_on = [
    azurerm_lb.pls,
  ]
}

resource "azurerm_network_interface_backend_address_pool_association" "pls" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  backend_address_pool_id = azurerm_lb_backend_address_pool.pls[each.value.name].id
  ip_configuration_name   = "internal"
  network_interface_id    = azurerm_network_interface.nic[each.value.name].id
  depends_on = [
    azurerm_lb_backend_address_pool.pls
  ]
}

resource "azurerm_private_link_service" "pls-service" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  load_balancer_frontend_ip_configuration_ids = [
    azurerm_lb.pls[each.value.name].frontend_ip_configuration.0.id
  ]
  location            = var.location
  name                = "${each.value.name}-lb-pvt-link-service"
  resource_group_name = module.postgresql[0].resource_group_name
  nat_ip_configuration {
    name      = "${each.value.name}-1"
    primary   = true
    subnet_id = azurerm_subnet.pls_subnet[0].id
  }
  tags = var.common_tags

  depends_on = [
    module.postgresql
  ]
}

resource "azurerm_lb_rule" "pls" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  loadbalancer_id                = azurerm_lb.pls[each.value.name].id
  name                           = "grafana-rule"
  frontend_ip_configuration_name = azurerm_lb.pls[each.value.name].frontend_ip_configuration.0.name
  frontend_port                  = "0"
  backend_port                   = "0"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pls[each.value.name].id]
  protocol                       = "All"
  enable_floating_ip             = "false"
  probe_id                       = azurerm_lb_probe.pls[each.value.name].id

  depends_on = [
    azurerm_lb.pls
  ]
}

resource "azurerm_lb_probe" "pls" {
  for_each = {
    for resource in var.private_link_resource : resource.name => resource
    if var.env == "prod"
  }

  loadbalancer_id     = azurerm_lb.pls[each.value.name].id
  name                = "grafana-health-probe"
  port                = 443
  protocol            = "Tcp"
  interval_in_seconds = 5
  number_of_probes    = 1
}
