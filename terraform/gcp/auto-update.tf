# --------------------------------------------------------------------------
# Auto-update: Cloud Scheduler polls Docker Hub every N minutes,
# Cloud Function compares digest and updates Cloud Run if different.
# No GitHub account / fork required on the operator's side.
# --------------------------------------------------------------------------

# APIs for Cloud Functions + Scheduler
resource "google_project_service" "auto_update_apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "cloudscheduler.googleapis.com",
    "eventarc.googleapis.com",
  ])

  project            = var.gcp_project
  service            = each.value
  disable_on_destroy = false
}

# Cloud Functions 2nd gen builds. Post-2024 Google change: 2nd gen builds
# run as the Compute default SA (not the legacy Cloud Build SA). New projects
# don't grant it builder role by default. Grant to BOTH SAs to cover both
# pre- and post-change project setups.
resource "google_project_iam_member" "cloudbuild_legacy_builder" {
  project = var.gcp_project
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"

  depends_on = [google_project_service.auto_update_apis]
}

resource "google_project_iam_member" "cloudbuild_compute_builder" {
  project = var.gcp_project
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${local.cloudbuild_sa}"

  depends_on = [google_project_service.auto_update_apis]
}

# Source bucket for function code
resource "google_storage_bucket" "function_source" {
  name                        = "${var.gcp_project}-pbfed-functions"
  project                     = var.gcp_project
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  force_destroy = true
}

# Zip the function source
data "archive_file" "auto_update_source" {
  type        = "zip"
  source_dir  = "${path.module}/functions/auto-update"
  output_path = "${path.module}/.terraform-tmp/auto-update.zip"
}

resource "google_storage_bucket_object" "auto_update_source" {
  name   = "auto-update-${data.archive_file.auto_update_source.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.auto_update_source.output_path
}

# Service account for the function (has Cloud Run admin + act-as runner)
resource "google_service_account" "auto_update_runner" {
  account_id   = "pbfed-auto-update"
  display_name = "peerBench Federated Auto-Update Function"
  project      = var.gcp_project
}

resource "google_project_iam_member" "auto_update_run_admin" {
  project = var.gcp_project
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.auto_update_runner.email}"
}

resource "google_service_account_iam_member" "auto_update_act_as_runner" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.auto_update_runner.email}"
}

# Function SA needs reader on AR repo: when it patches Cloud Run with a new
# image URL, GCP checks the caller has downloadArtifacts on that image.
resource "google_artifact_registry_repository_iam_member" "auto_update_repo_reader" {
  project    = var.gcp_project
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.auto_update_runner.email}"
}

# The function
resource "google_cloudfunctions2_function" "auto_update" {
  name     = "pbfed-auto-update"
  location = var.gcp_region
  project  = var.gcp_project

  build_config {
    runtime     = "nodejs22"
    entry_point = "checkAndUpdate"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.auto_update_source.name
      }
    }
  }

  service_config {
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.auto_update_runner.email

    environment_variables = {
      PROJECT      = var.gcp_project
      REGION       = var.gcp_region
      SERVICE_NAME = var.cloud_run_service_name
      # Function polls Docker Hub directly for the digest, then patches Cloud Run
      # with the AR-mirrored URL (which transparently fetches from Docker Hub).
      IMAGE_HUB_REPO = "docker.io/${var.image_repo_path}"
      IMAGE_AR_REPO  = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project}/${google_artifact_registry_repository.images.repository_id}/${var.image_repo_path}"
      IMAGE_TAG      = var.image_tag
    }
  }

  depends_on = [
    google_project_service.auto_update_apis,
    google_project_iam_member.cloudbuild_legacy_builder,
    google_project_iam_member.cloudbuild_compute_builder,
  ]
}

# Scheduler service account (allowed to invoke the function)
resource "google_service_account" "scheduler_invoker" {
  account_id   = "pbfed-scheduler"
  display_name = "peerBench Auto-Update Scheduler Invoker"
  project      = var.gcp_project
}

resource "google_cloud_run_service_iam_member" "scheduler_can_invoke" {
  project  = var.gcp_project
  location = var.gcp_region
  service  = google_cloudfunctions2_function.auto_update.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

# Scheduler job — cron every 5 minutes
resource "google_cloud_scheduler_job" "auto_update" {
  name     = "pbfed-auto-update-poll"
  schedule = "*/5 * * * *"
  region   = var.gcp_region
  project  = var.gcp_project

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.auto_update.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.scheduler_invoker.email
      audience              = google_cloudfunctions2_function.auto_update.service_config[0].uri
    }
  }

  depends_on = [
    google_project_service.auto_update_apis,
  ]
}
