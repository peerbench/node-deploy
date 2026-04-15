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
  description = "Custom domain for the node (e.g. pbfed.mit.edu). Optional — leave empty to deploy on the auto-generated Cloud Run URL (no DNS setup, no SSL wait). When set, tofu creates a load balancer + managed SSL cert, and the operator must add a DNS A record pointing this domain to the LB IP after apply."
  type        = string
  default     = ""
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

# --------------------------------------------------------------------------
# Node profile (wizard step 2 — auto-filled so the operator skips straight
# to the service account step)
# --------------------------------------------------------------------------

variable "node_display_name" {
  description = "Human-readable name shown in federation listings (e.g. \"MIT peerBench Node\"). The coding agent typically derives this from the domain slug or the node name provided at the start of the flow."
  type        = string
}

variable "node_handle" {
  description = "Short slug used as the service account handle on the identity server (e.g. 'pbfed' or 'mit-lab'). Agent should derive a short value from the first subdomain component of the custom domain, or from the project name for auto-URL deploys. Leave empty to let the wizard derive it from the display name (which often ends up too long)."
  type        = string
  default     = ""
}

variable "node_login_policy" {
  description = "Who can create user accounts on this node: open | request-approval | invite-only"
  type        = string
  default     = "request-approval"
  validation {
    condition     = contains(["open", "request-approval", "invite-only"], var.node_login_policy)
    error_message = "node_login_policy must be one of: open, request-approval, invite-only"
  }
}

# --------------------------------------------------------------------------
# Federation endpoints (wizard step 1 — auto-filled, operator never sees
# these unless they override here)
# --------------------------------------------------------------------------

variable "pds_url" {
  description = "Identity server (Personal Data Server) used for operator + user sign-in."
  type        = string
  default     = "https://p.0rs.org"
}

variable "plc_url" {
  description = "PLC directory for DID resolution."
  type        = string
  default     = "https://plc.directory"
}

variable "indexer_url" {
  description = "Federation indexer that coordinates data across all peerBench nodes."
  type        = string
  default     = "https://indexer.peerbench.ai"
}
