locals {
  # AnyObjectRead access_uri ends at /o/ ; trim it so callers can append
  # "/<object>" without doubling the separator.
  par_base = format("https://objectstorage.%s.%s%s",
    var.region,
    var.realm_domain,
    trimsuffix(oci_objectstorage_preauthrequest.artifacts.access_uri, "/")
  )
}

output "provider_artifacts_base_url" {
  description = "Base URL the provider-installer Job prepends to the component manifest filenames. Expires with the PAR."
  value       = local.par_base
}

output "cluster_autoscaler_repository_url" {
  description = "Helm repository URL for the cluster-autoscaler chart. Helm appends /index.yaml, which matches the charts/index.yaml object. Chart URLs inside that index must be relative, or absolute against this same PAR."
  value       = "${local.par_base}/charts"
}

output "par_expires" {
  description = "When the PAR stops working. The autoscaler operator may re-run the installer Job on upgrade or reconcile long after install, and the fetch fails once this passes."
  value       = oci_objectstorage_preauthrequest.artifacts.time_expires
}

output "staged_objects" {
  description = "Artifacts actually uploaded. Anything absent here was not given a local path and will not be served."
  value       = [for k, v in local.staged : v.object]
}
