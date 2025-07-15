env                   = "prod"
dashboard_count       = 1
grafana_major_version = 11
budget_start_date     = "2025-07-01T00:00:00Z"
pgsql_public_access   = false

private_link_resource = [
  {
    name              = "dtsse-grafana"
    service_endpoints = []
  }
]
