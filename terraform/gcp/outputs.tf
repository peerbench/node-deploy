output "node_url" {
  description = "Public URL of the deployed node (custom domain). Open this to complete the setup wizard once DNS + SSL are ready."
  value       = "https://${var.custom_domain}"
}

output "load_balancer_ip" {
  description = "Static IP of the HTTPS load balancer. Add an A record at your DNS provider pointing your custom_domain to this IP."
  value       = google_compute_global_address.lb.address
}

output "cloud_run_url" {
  description = "Direct Cloud Run URL (use only for debugging — production traffic goes through the LB)"
  value       = google_cloud_run_v2_service.node.uri
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL instance connection name (for debugging)"
  value       = local.sql_connection_name
}

# --------------------------------------------------------------------------
# Storage credentials — paste these into the setup wizard
# --------------------------------------------------------------------------

output "storage_bucket_name" {
  description = "GCS bucket name for file storage. Paste into wizard."
  value       = google_storage_bucket.node_storage.name
}

output "storage_endpoint" {
  description = "S3-compatible endpoint for GCS. Paste into wizard."
  value       = "https://storage.googleapis.com"
}

output "storage_region" {
  description = "Bucket location/region for the S3 client config. Paste into wizard."
  value       = google_storage_bucket.node_storage.location
}

output "storage_access_key_id" {
  description = "HMAC access key ID. Paste into wizard."
  value       = google_storage_hmac_key.node_storage_hmac.access_id
  sensitive   = true
}

output "storage_secret_access_key" {
  description = "HMAC secret. Paste into wizard. Run 'tofu output storage_secret_access_key' to view."
  value       = google_storage_hmac_key.node_storage_hmac.secret
  sensitive   = true
}
