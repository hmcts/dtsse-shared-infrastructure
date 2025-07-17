variable "common_tags" {
  type = map(string)
}

variable "product" {
  default = "dtsse"
}
variable "env" {}
variable "tenant_id" {}

variable "location" {
  default = "UK South"
}

variable "managed_identity_object_id" {
  default = ""
}

variable "jenkins_AAD_objectId" {
  description = "(Required) The Azure AD object ID of a user, service principal or security group in the Azure Active Directory tenant for the vault. The object ID must be unique for the list of access policies."
}

variable "subscription" {}

variable "aks_subscription_id" {}

variable "dashboard_count" {
  default = 1
  type    = number
}

variable "grafana_major_version" {
  default     = 10
  description = "Specifies the major version of Grafana to deploy 10"
  type        = number
}

variable "api_key_enabled" {
  default     = true
  description = "Specifies whether API Keys can be generated"
  type        = bool
}

variable "zone_redundancy_enabled" {
  default     = false
  description = "Specifies whether enable the zone redundancy setting of the Grafana instance."
  type        = bool
}

variable "budget_start_date" {
  default     = "2024-10-01T00:00:00Z"
  description = "The start date for the budget in ISO 8601 format."
  type        = string
}

variable "public_network_access_enabled" {
  default     = true
  description = "Specifies whether public network access is enabled for the Grafana instance."
  type        = bool
}

variable "pgsql_public_access" {
  default     = true
  description = "Specifies whether public access is enabled for the PostgreSQL Flexible Server."
  type        = bool
}
