# --------------------------------------------------------------------------
# Locals
# --------------------------------------------------------------------------

locals {
  sql_connection_name = google_sql_database_instance.postgres.connection_name
  database_url        = "postgresql://${google_sql_user.app.name}:${random_password.db_password.result}@localhost/pbfed?host=/cloudsql/${local.sql_connection_name}"
  # AR remote repo proxies Docker Hub. peerbench/pbfed-node on hub is reachable as
  # {region}-docker.pkg.dev/{project}/pbfed-images/peerbench/pbfed-node
  image_path = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project}/pbfed-images/${var.image_repo_path}:latest"
  # Placeholder image used until auto-update function pulls the real digest.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"
}

# --------------------------------------------------------------------------
# Project number (needed for Cloud Build default service account)
# --------------------------------------------------------------------------

data "google_project" "project" {
  project_id = var.gcp_project
}

# --------------------------------------------------------------------------
# APIs
# --------------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "storage.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  project            = var.gcp_project
  service            = each.value
  disable_on_destroy = false
}

# --------------------------------------------------------------------------
# Generated secrets
# --------------------------------------------------------------------------

resource "random_password" "db_password" {
  length  = 32
  special = false
}

# --------------------------------------------------------------------------
# VPC Peering for Cloud SQL private IP
# --------------------------------------------------------------------------

data "google_compute_network" "default" {
  name    = "default"
  project = var.gcp_project

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

data "google_compute_subnetwork" "default" {
  name    = "default"
  region  = var.gcp_region
  project = var.gcp_project

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "pbfed-sql-private-ip"
  project       = var.gcp_project
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.default.id
}

resource "google_service_networking_connection" "sql_private_vpc" {
  network                 = data.google_compute_network.default.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.apis["servicenetworking.googleapis.com"]]
}

# --------------------------------------------------------------------------
# Cloud SQL (private IP only — no public IP costs, no public attack surface)
# --------------------------------------------------------------------------

resource "google_sql_database_instance" "postgres" {
  name             = "pbfed-postgres"
  project          = var.gcp_project
  region           = var.gcp_region
  database_version = "POSTGRES_15"

  settings {
    tier      = "db-f1-micro"
    disk_type = "PD_HDD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.default.id
    }
  }

  deletion_protection = true

  depends_on = [
    google_project_service.apis["sqladmin.googleapis.com"],
    google_service_networking_connection.sql_private_vpc,
  ]
}

resource "google_sql_database" "app" {
  name     = "pbfed"
  instance = google_sql_database_instance.postgres.name
  project  = var.gcp_project
}

resource "google_sql_user" "app" {
  name     = "pbfed_user"
  instance = google_sql_database_instance.postgres.name
  password = random_password.db_password.result
  project  = var.gcp_project
}

# --------------------------------------------------------------------------
# Service Account (for Cloud Run)
# --------------------------------------------------------------------------

resource "google_service_account" "runner" {
  account_id   = "pbfed-runner"
  display_name = "peerBench Federated Cloud Run Runner"
  project      = var.gcp_project
}

resource "google_project_iam_member" "runner_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/artifactregistry.reader",
  ])

  project = var.gcp_project
  role    = each.value
  member  = "serviceAccount:${google_service_account.runner.email}"
}

# Compute default SA — used by Cloud Functions 2nd gen builds.
# (Referenced in auto-update.tf to grant builder role.)
locals {
  cloudbuild_sa = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# --------------------------------------------------------------------------
# Artifact Registry (Docker image repo)
# --------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  location      = var.gcp_region
  repository_id = "pbfed-images"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  project       = var.gcp_project

  remote_repository_config {
    description = "Mirror of Docker Hub for pbfed-node image"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

# Explicit grant on the repo (project-level reader sometimes isn't enough
# for REMOTE_REPOSITORY mode — Cloud Run can fail to download artifacts).
resource "google_artifact_registry_repository_iam_member" "runner_repo_reader" {
  project    = var.gcp_project
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.runner.email}"
}

# --------------------------------------------------------------------------
# GCS Bucket for file storage (uploads, image generation outputs, etc.)
# Backend uses S3-compatible API via @aws-sdk/client-s3 + HMAC key.
# Operator pastes the HMAC creds + bucket name into the setup wizard.
# --------------------------------------------------------------------------

resource "google_storage_bucket" "node_storage" {
  name                        = "${var.gcp_project}-pbfed-storage"
  project                     = var.gcp_project
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  depends_on = [google_project_service.apis["storage.googleapis.com"]]
}

resource "google_storage_bucket_iam_member" "node_storage_admin" {
  bucket = google_storage_bucket.node_storage.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_storage_hmac_key" "node_storage_hmac" {
  project               = var.gcp_project
  service_account_email = google_service_account.runner.email
}

# --------------------------------------------------------------------------
# Cloud Run
# Image starts as placeholder; first run of Cloud Build trigger pushes the
# real image and updates the service. lifecycle.ignore_changes keeps tofu
# from fighting subsequent image updates from the trigger.
# --------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "node" {
  name     = "pbfed-node"
  location = var.gcp_region
  project  = var.gcp_project

  template {
    service_account = google_service_account.runner.email

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    # Direct VPC egress — required because Cloud SQL is private-IP only.
    # Uses 2nd gen Cloud Run's direct VPC feature (no Serverless VPC Access
    # Connector needed — free).
    vpc_access {
      network_interfaces {
        network    = data.google_compute_network.default.id
        subnetwork = data.google_compute_subnetwork.default.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.sql_connection_name]
      }
    }

    containers {
      image = local.placeholder_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # Only DATABASE_URL is set by Terraform directly — the rest
      # (NODE_PUBLIC_URL, STORAGE_*, profile, federation endpoints) is
      # patched in after create by null_resource.set_env. That way we can
      # use the live Cloud Run URL for NODE_PUBLIC_URL when no custom
      # domain is configured.
      env {
        name  = "DATABASE_URL"
        value = local.database_url
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
    ]
  }

  depends_on = [
    google_project_iam_member.runner_roles,
  ]
}

# --------------------------------------------------------------------------
# Runtime env injection
# --------------------------------------------------------------------------
#
# Patches the full set of runtime env vars onto the Cloud Run service after
# it exists. Required because NODE_PUBLIC_URL has to reference the Cloud Run
# URI when no custom domain is set, which would be a self-reference inside
# the same resource block. gcloud's `^@@^` delimiter lets us pass values
# that may contain commas safely. Re-runs whenever any of the tracked
# values change.
resource "null_resource" "set_env" {
  triggers = {
    service_uri       = google_cloud_run_v2_service.node.uri
    custom_domain     = var.custom_domain
    node_display_name = var.node_display_name
    node_login_policy = var.node_login_policy
    pds_url           = var.pds_url
    plc_url           = var.plc_url
    indexer_url       = var.indexer_url
    bucket            = google_storage_bucket.node_storage.name
    bucket_location   = google_storage_bucket.node_storage.location
    hmac_access       = google_storage_hmac_key.node_storage_hmac.access_id
    hmac_secret       = google_storage_hmac_key.node_storage_hmac.secret
  }

  provisioner "local-exec" {
    environment = {
      HMAC_SECRET = google_storage_hmac_key.node_storage_hmac.secret
    }
    command = <<-EOT
      PUBLIC_URL="${var.custom_domain != "" ? "https://${var.custom_domain}" : google_cloud_run_v2_service.node.uri}"
      gcloud run services update ${google_cloud_run_v2_service.node.name} \
        --project=${var.gcp_project} \
        --region=${var.gcp_region} \
        --update-env-vars="^@@^NODE_PUBLIC_URL=$PUBLIC_URL@@NODE_DISPLAY_NAME=${var.node_display_name}@@NODE_LOGIN_POLICY=${var.node_login_policy}@@PDS_URL=${var.pds_url}@@PLC_URL=${var.plc_url}@@INDEXER_URL=${var.indexer_url}@@STORAGE_ENDPOINT=https://storage.googleapis.com@@STORAGE_REGION=${google_storage_bucket.node_storage.location}@@STORAGE_BUCKET=${google_storage_bucket.node_storage.name}@@STORAGE_ACCESS_KEY=${google_storage_hmac_key.node_storage_hmac.access_id}@@STORAGE_SECRET_KEY=$HMAC_SECRET"
    EOT
  }

  depends_on = [google_cloud_run_v2_service.node]
}

# Allow unauthenticated access (public web app)
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  project  = var.gcp_project
  location = var.gcp_region
  name     = google_cloud_run_v2_service.node.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --------------------------------------------------------------------------
# HTTPS Load Balancer (Google-managed SSL, no Search Console verification)
# --------------------------------------------------------------------------

#
# Everything below is skipped when no custom domain is configured — the
# node is reached directly via the Cloud Run auto-generated URL instead.
#
locals {
  lb_count = var.custom_domain != "" ? 1 : 0
}

resource "google_compute_region_network_endpoint_group" "neg" {
  count                 = local.lb_count
  name                  = "pbfed-neg"
  project               = var.gcp_project
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.node.name
  }
}

resource "google_compute_backend_service" "backend" {
  count   = local.lb_count
  name    = "pbfed-backend"
  project = var.gcp_project

  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL"

  backend {
    group = google_compute_region_network_endpoint_group.neg[0].id
  }
}

resource "google_compute_url_map" "lb" {
  count           = local.lb_count
  name            = "pbfed-url-map"
  project         = var.gcp_project
  default_service = google_compute_backend_service.backend[0].id
}

resource "google_compute_managed_ssl_certificate" "lb" {
  count   = local.lb_count
  name    = "pbfed-cert"
  project = var.gcp_project

  managed {
    domains = [var.custom_domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "lb" {
  count            = local.lb_count
  name             = "pbfed-https-proxy"
  project          = var.gcp_project
  url_map          = google_compute_url_map.lb[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.lb[0].id]
}

resource "google_compute_global_address" "lb" {
  count   = local.lb_count
  name    = "pbfed-lb-ip"
  project = var.gcp_project
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = local.lb_count
  name                  = "pbfed-https-rule"
  project               = var.gcp_project
  ip_address            = google_compute_global_address.lb[0].address
  port_range            = "443"
  target                = google_compute_target_https_proxy.lb[0].id
  load_balancing_scheme = "EXTERNAL"
}

# HTTP -> HTTPS redirect
resource "google_compute_url_map" "http_redirect" {
  count   = local.lb_count
  name    = "pbfed-http-redirect"
  project = var.gcp_project

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  count   = local.lb_count
  name    = "pbfed-http-proxy"
  project = var.gcp_project
  url_map = google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http" {
  count                 = local.lb_count
  name                  = "pbfed-http-rule"
  project               = var.gcp_project
  ip_address            = google_compute_global_address.lb[0].address
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_redirect[0].id
  load_balancing_scheme = "EXTERNAL"
}
