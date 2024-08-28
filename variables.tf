
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
  default = 10
  description = "Specifies the major version of Grafana to deploy 10"
  type    = number
}

variable "api_key_enabled" {
  default = true
  description = "Specifies whether API Keys can be generated"
  type    = bool
}

variable "zone_redundancy_enabled" {
  default = true
  description = "Specifies whether enable the zone redundancy setting of the Grafana instance."
  type    = bool
}
