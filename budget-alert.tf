resource "azurerm_consumption_budget_resource_group" "grafana-budget-alert" {
  count             = var.dashboard_count
  name              = "grafana-budget-alert"
  resource_group_id = azurerm_resource_group.rg.id

  amount     = 500
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  filter {
    dimension {
      name = "ResourceId"
      values = [
        azurerm_dashboard_grafana.main[0].id,
      ]
    }
  }

  notification {
    enabled        = true
    threshold      = 90.0
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted"

    contact_groups = [
      module.alert-action-group.action_group_id
    ]
  }
}
