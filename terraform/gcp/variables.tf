# --------------------------------------------------------------------------
# Required
# --------------------------------------------------------------------------

variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for all resources"
  type        = string
  default     = "europe-west1"
}

variable "custom_domain" {
  description = "Custom domain for the node (e.g. pbfed.mit.edu). Required. After tofu apply, add a DNS A record pointing this domain to the LB IP from outputs."
  type        = string
}

variable "image_repo_path" {
  description = "Image path on Docker Hub (namespace + image name)."
  type        = string
  default     = "leipniz/pbfed-node"
}

variable "image_tag" {
  description = "Container image tag to track (default: latest)"
  type        = string
  default     = "latest"
}
