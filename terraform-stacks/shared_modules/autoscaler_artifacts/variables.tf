variable "compartment_ocid" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "realm_domain" {
  type    = string
  default = "oraclecloud.com"
}

variable "par_expiry_hours" {
  type    = number
  default = 168
}

variable "defined_tags" {
  type = map(string)
}

# Versions are used to build the object names, so what is staged can never
# drift from what the provider-installer Job asks for.
variable "cert_manager_version" {
  type = string
}

variable "capi_version" {
  type = string
}

variable "capoci_version" {
  type = string
}

variable "cluster_autoscaler_chart_version" {
  type = string
}

# Local paths to artifacts staged on the machine running terraform. Download
# these on a connected host and carry them into the enclave.
variable "cert_manager_manifest_path" {
  type    = string
  default = ""
}

variable "capi_manifest_path" {
  type    = string
  default = ""
}

variable "capoci_manifest_path" {
  type    = string
  default = ""
}

variable "helm_index_path" {
  type    = string
  default = ""
}

variable "helm_chart_path" {
  type    = string
  default = ""
}
