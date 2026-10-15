terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.12.0"
    }
  }
}

# The autoscaler's provider-installer Job fetches three component manifests
# and a Helm chart over plain HTTPS from github.com, which an air-gapped
# cluster cannot reach. Host them in Object Storage instead and hand the Job
# a base URL.
#
# A pre-authenticated request rather than instance principals: the Job runs
# curl and 'oc apply -f <url>', neither of which can sign an OCI API request,
# and it carries no nodeSelector or tolerations so it lands on a worker —
# whose dynamic group is not granted manage objects. An unauthenticated URL
# is the only thing that works without rebuilding Oracle's installer image.

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "autoscaler_artifacts" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.cluster_name}-autoscaler-artifacts"
  access_type    = "NoPublicAccess"
  defined_tags   = var.defined_tags
}

locals {
  # Object names are derived from the component versions so they always match
  # the URLs the Job builds from the same variables.
  artifacts = {
    cert_manager = {
      object = "cert-manager-${var.cert_manager_version}.yaml"
      source = var.cert_manager_manifest_path
    }
    capi = {
      object = "cluster-api-${var.capi_version}.yaml"
      source = var.capi_manifest_path
    }
    capoci = {
      object = "cluster-api-provider-oci-${var.capoci_version}.yaml"
      source = var.capoci_manifest_path
    }
    helm_index = {
      object = "charts/index.yaml"
      source = var.helm_index_path
    }
    helm_chart = {
      object = "charts/cluster-autoscaler-${var.cluster_autoscaler_chart_version}.tgz"
      source = var.helm_chart_path
    }
  }

  staged = { for k, v in local.artifacts : k => v if v.source != "" }
}

resource "oci_objectstorage_object" "artifact" {
  for_each = local.staged

  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.autoscaler_artifacts.name
  object    = each.value.object
  source    = each.value.source
}

# AnyObjectRead rather than ObjectRead: one PAR has to serve five objects, so
# the token is scoped to the bucket and the consumer appends the object name.
resource "oci_objectstorage_preauthrequest" "artifacts" {
  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = oci_objectstorage_bucket.autoscaler_artifacts.name
  name         = "${var.cluster_name}-autoscaler-artifacts-par"
  access_type  = "AnyObjectRead"
  time_expires = timeadd(timestamp(), "${var.par_expiry_hours}h")

  # Nothing orders the PAR after the uploads otherwise, and a consumer could
  # resolve the URL before the objects exist.
  depends_on = [oci_objectstorage_object.artifact]

  lifecycle {
    ignore_changes = [time_expires]
  }
}
