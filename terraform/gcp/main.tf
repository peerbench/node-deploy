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

      env {
        name  = "DATABASE_URL"
        value = local.database_url
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }

  depends_on = [
    google_project_iam_member.runner_roles,
  ]
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

resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "pbfed-neg"
  project               = var.gcp_project
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.node.name
  }
}

resource "google_compute_backend_service" "backend" {
  name    = "pbfed-backend"
  project = var.gcp_project

  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL"

  backend {
    group = google_compute_region_network_endpoint_group.neg.id
  }
}

resource "google_compute_url_map" "lb" {
  name            = "pbfed-url-map"
  project         = var.gcp_project
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_managed_ssl_certificate" "lb" {
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
  name             = "pbfed-https-proxy"
  project          = var.gcp_project
  url_map          = google_compute_url_map.lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.lb.id]
}

resource "google_compute_global_address" "lb" {
  name    = "pbfed-lb-ip"
  project = var.gcp_project
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "pbfed-https-rule"
  project               = var.gcp_project
  ip_address            = google_compute_global_address.lb.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.lb.id
  load_balancing_scheme = "EXTERNAL"
}

# HTTP -> HTTPS redirect
resource "google_compute_url_map" "http_redirect" {
  name    = "pbfed-http-redirect"
  project = var.gcp_project

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  name    = "pbfed-http-proxy"
  project = var.gcp_project
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "pbfed-http-rule"
  project               = var.gcp_project
  ip_address            = google_compute_global_address.lb.address
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_redirect.id
  load_balancing_scheme = "EXTERNAL"
}
