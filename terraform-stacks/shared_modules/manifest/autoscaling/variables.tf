variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "op_vcn_id" { type = string }
variable "op_subnet_private_ocp" { type = string }
variable "op_network_security_group_cluster_lb_nsg" { type = string }
variable "op_lb_openshift_api_lb" { type = string }
variable "op_lb_openshift_api_lb_ip_addr" { type = string }
variable "cluster_name" { type = string }
variable "capi_version" {
  type    = string
  default = "v1.14.0"
}

variable "capoci_version" {
  type    = string
  default = "v0.24.0"
}

variable "cluster_network_cidr_block" {
  type    = string
  default = "10.128.0.0/14"
}

variable "service_network_cidr_block" {
  type    = string
  default = "172.30.0.0/16"
}

variable "autoscaler_defined_tags_namespace" {
  type    = string
  default = ""
}

variable "bare_metal_subnet_id" { type = string }
variable "bare_metal_subnet_name" { type = string }
variable "ocp_subnet_name" { type = string }

variable "autoscaler_node_shape" { type = string }
variable "autoscaler_node_minimum_count" { type = number }
variable "autoscaler_node_maximum_count" { type = number }
variable "autoscaler_pool_identifier" {
  type = string

  validation {
    condition     = var.autoscaler_pool_identifier == "" || can(regex("^[a-z0-9]([-a-z0-9]{0,3}[a-z0-9])?$", var.autoscaler_pool_identifier))
    error_message = "The autoscaler_pool_identifier value must be empty or up to 5 characters containing lowercase letters, numbers, and hyphens, and must start and end with a lowercase letter or number."
  }
}
variable "autoscaler_node_ocpus" { type = number }
variable "autoscaler_node_memory" { type = number }
variable "autoscaler_node_image_id" { type = string }

# Autoscaler artifact sources. Mirrors the same inputs on the parent manifest
# module. Empty base URL means the provider-installer Job fetches from
# github.com, which only works on a connected cluster.
variable "cert_manager_version" {
  type    = string
  default = "v1.16.3"
}

variable "provider_artifacts_base_url" {
  type    = string
  default = ""
}

variable "cluster_autoscaler_repository_url" {
  type    = string
  default = "https://kubernetes.github.io/autoscaler"
}

variable "provider_installer_image" {
  type    = string
  default = "quay.io/openshift/origin-cli:4.22"
}
