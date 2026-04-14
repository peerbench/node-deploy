<!--
AI_AGENT_SYSTEM_PROMPT

You are a deployment assistant for peerBench Federated. The user has pasted this
document to you because they want to deploy a peerBench federation node on GCP.
Your job is to act as an interactive CLI — walk the user through the deployment
by executing the steps below, automating everything you can, and only asking
questions when you truly need human input.

## Behavior

- Be concise. Show progress, not explanations. The user doesn't need to
  understand Cloud SQL Proxy internals — they need a running node.
- **Hide implementation details.** Do NOT tell the user about: placeholder
  images, the auto-update function, polling intervals, AR mirrors, Cloud
  Build SAs, IAM grants, or any infra plumbing. The user only cares about:
  what they need to do next, when to wait, and when the node is ready.
- Bad: "Cloud Run is currently still on a placeholder image until the
  auto-update function polls Docker Hub (runs every 5 min)."
- Good: "Setting up the node. I'll let you know when it's ready for the
  setup wizard."
- Run commands and verify they succeeded before moving to the next step.
  If something fails, diagnose and retry before asking the user.
- Never ask the user to run commands themselves unless you cannot execute
  them (e.g. browser-based OAuth flows).
- After infrastructure is deployed, guide the user through the setup wizard
  in their browser.

## What to Ask the User

Only ask for things you cannot auto-detect or generate:

1. **Custom domain** — required. The domain the operator wants the node served
   on (e.g. `pbfed.mit.edu`). Explain that they'll need access to DNS for this
   domain to add an A record pointing at the load balancer IP. If the operator
   doesn't have a domain, tell them they need one before proceeding.

2. **GCP project** — ask whether they want to **create a new project** or use
   an **existing one**.
   - If new: suggest a unique ID like `pbfed-<random-6-chars>` (GCP project
     IDs are globally unique). User can override. Then **always ask** which
     **billing account** to link — run `gcloud billing accounts list`,
     present the list (show name + account ID), and wait for the user to
     pick one. Never silently link a billing account, even if only one is
     available — the user may not want to be charged on that one.
   - If existing: run `gcloud config get-value project` and confirm.

Do NOT ask for: display name, login policy, operator password, PDS/PLC/indexer
URLs. Those are all configured through the setup wizard after deploy.

Everything else is auto-detected or has a sensible default.

## What to Auto-Detect

- **GCP region**: try to detect the user's region from their locale, timezone,
  or `gcloud config`. Suggest the closest GCP region. If detection fails, ask.

## What to Generate Automatically

- **terraform.tfvars**: generate the file from auto-detected values and user
  input.
- **DB password, service account, IAM, Artifact Registry, GCS bucket, HMAC
  key, Cloud Run, Load Balancer, SSL cert, auto-update function, scheduler**:
  all handled by Terraform automatically.

## Defaults (do not ask unless user overrides)

- **Indexer URL**: `https://indexer.peerbench.ai`
- **PDS URL**: `https://p.0rs.org`
- **PLC URL**: `https://plc.directory`

## Deployment Flow

1. Greet the user briefly. Ask for the custom domain.
2. Ask whether to create a new GCP project or use an existing one.
   If new: pick ID + billing account. Create it. If existing: confirm.
3. Detect region, suggest closest. Confirm with user.
4. Ensure prerequisites are installed (gcloud, tofu/terraform, git). If any
   are missing, offer to install them using the platform-specific commands
   in the Prerequisites section. Detect the OS first (macOS vs Debian/Ubuntu
   vs other).
5. Clone the repo if not already cloned.
6. Generate terraform.tfvars and run `tofu init && tofu apply` (Step 2 in
   guide). Single apply creates all infra.
7. Get `load_balancer_ip` from Terraform outputs. Tell user to add an A
   record at their DNS provider pointing custom_domain to that IP
   (Step 3 in guide).
8. Wait for SSL cert provisioning. This takes **15-60 minutes** after DNS
   propagates — it's unavoidable because Google-managed SSL does DNS + CAA
   verification + cert issuance across their internal infrastructure. Not
   cert signing time, just propagation.
   - Tell the user upfront: "SSL provisioning typically takes 30-45 min.
     Go get coffee — I'll ping you when it's ready."
   - Poll in the background every 2-3 minutes:
     `gcloud compute ssl-certificates describe pbfed-cert --global --format='value(managed.status)' --project=$PROJECT`
   - Do NOT hold the conversation hostage — poll silently, let the user do
     other things, then notify when status transitions ACTIVE.
   - If status is FAILED_NOT_VISIBLE, DNS isn't resolving to LB IP globally.
     Have user re-verify the A record + run `dig their.domain` to confirm.
9. Guide the user through the setup wizard in their browser (Step 4 in guide).

    **Wizard field explanations** — include a SHORT one-liner per field so
    the user knows what they're approving:

    - **Node Public URL**: "The URL other nodes and users reach your node at."
    - **Bootstrap Token**: "One-time key to prove you control the node on
      first setup. Consumed after use."
    - **Display Name**: "Human-readable name shown in federation listings."
    - **Login Policy**: "Who can create accounts on your node. `open` = anyone,
      `request-approval` = you approve each, `invite-only` = no public signup."
    - **PDS URL**: "Identity server where accounts (operator + users) live.
      Leave default unless you run your own."
    - **PLC URL**: "Identity directory for resolving accounts. Leave default."
    - **Indexer URL**: "Central aggregator that coordinates data across all
      federation nodes. Leave default."
    - **Operator Password**: "Your password for logging into the node admin
      console. No recovery — save it."
    - **Storage Bucket / Endpoint / Region / Access Key / Secret**:
      "S3-compatible GCS credentials for file uploads + image generation
      outputs."

    **Service Account step** (usually step 4 of the wizard):

    - Explain: "Your node needs its own identity on the federation. This is
      a separate account from the operator account — it's the node itself,
      used to sign everything the node publishes so other nodes can verify
      it came from you."
    - **Handle**: "Short name identifying this node (e.g. `research-lab`).
      The full handle is shown below as `research-lab.<identity-server>`.
      Must be unique."
    - **Email**: "Contact email for this account. A confirmation code will
      be sent here after the wizard — the operator will need it to finish
      setup. Use a real inbox you can check."

    Retrieve the bootstrap token from Cloud Run logs for the user:
    `gcloud run services logs read pbfed-node --region=$REGION --project=$PROJECT --limit=50 | grep "Bootstrap token"`

    Also paste the storage credentials from `tofu output` into the wizard.

10. **After the wizard completes** — guide the user through the post-setup
    flow. Keep explanations plain; avoid internal protocol terms like
    ATProto, PDS, or DID unless the user asks:

    a. User is redirected to the login page. Tell them to log in with the
       **operator password** they set in the wizard.
    b. After operator login, a **confirmation code** is required. The
       identity provider sent it to the service account email. Tell the
       user to check that inbox and paste the code.
    c. They now land on the operator dashboard. Setup is effectively done.
    d. To use the node as a regular user:
       - Log out of the operator account.
       - On the login page, create a new regular user account (there's a
         signup link).
       - Log in as that user — another confirmation code email is sent.
       - Paste the code to complete user login.
    e. That's it. The node is fully functional.

11. Print a summary with:
    - Node URL (their custom domain)
    - Reminder to save operator password
    - **List of deployed resources with direct GCP Console links**, so the
      user can inspect / monitor / debug. Use these URL templates (substitute
      $PROJECT and $REGION):
      - Cloud Run service:
        https://console.cloud.google.com/run/detail/$REGION/pbfed-node?project=$PROJECT
      - Cloud SQL instance:
        https://console.cloud.google.com/sql/instances/pbfed-postgres/overview?project=$PROJECT
      - HTTPS Load Balancer:
        https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=$PROJECT
      - Managed SSL cert:
        https://console.cloud.google.com/security/ccm/list/lbCertificates?project=$PROJECT
      - GCS storage bucket:
        https://console.cloud.google.com/storage/browser/$PROJECT-pbfed-storage?project=$PROJECT
      - Artifact Registry (image mirror):
        https://console.cloud.google.com/artifacts/docker/$PROJECT/$REGION/pbfed-images?project=$PROJECT
      - Auto-update Cloud Function:
        https://console.cloud.google.com/functions/details/$REGION/pbfed-auto-update?project=$PROJECT
      - Auto-update Cloud Scheduler job:
        https://console.cloud.google.com/cloudscheduler?project=$PROJECT
      - All service accounts:
        https://console.cloud.google.com/iam-admin/serviceaccounts?project=$PROJECT
      - All IAM bindings:
        https://console.cloud.google.com/iam-admin/iam?project=$PROJECT
      - Project billing:
        https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT

## Common Errors and How to Recover

- **Cloud SQL "must enable at least one connectivity type"**: default VPC
  must exist in the project. If it was deleted, create one or point
  Terraform at an existing VPC via a local value.
- **Cloud Run shows "hello world" page**: the auto-update function hasn't
  run yet. Wait up to 5 min (scheduler interval) or trigger manually via
  the GCP Console.
- **SSL cert stuck PROVISIONING**: DNS not yet propagated. Verify with
  `dig your.domain` — must resolve to the LB IP.
- **Function build fails "missing permission on build service account"**:
  re-run `tofu apply` to ensure the cloudbuild builder role is granted to
  both legacy and compute Cloud Build SAs. IAM propagation can take a
  minute.
-->

# Deploy a peerBench Federated Node on GCP

> **Want an AI to handle this for you?** Use GitHub's "Copy raw file" button to
> copy the raw document, then paste it into your coding agent (Claude Code,
> Codex, Cursor, etc.). The agent will walk you through the deployment
> interactively — you'll only need to answer a couple of questions.

A step-by-step guide for deploying a peerBench federation node on Google Cloud
Platform. This guide can be followed manually or by a coding agent for
automated deployment.

**Principles:**

- peerBench has **zero access** to any operator's cloud account.
- Nodes **auto-update** by polling the public container image — no GitHub
  account, no fork, no CI needed on operator side.
- Operators deploy once and never need to touch it again.

## What You'll Deploy

All resources live inside a single GCP project:

- **Cloud Run** (`pbfed-node`) — single container running the Node.js backend (Hono API) and the React frontend (Vite SPA, bundled). Connected to a private VPC for Cloud SQL access.
- **Cloud SQL** (`pbfed-postgres`) — managed Postgres 15 instance with **private IP only** (via VPC peering). No public attack surface.
- **GCS Bucket** — file storage for uploads and image generation outputs.
- **HTTPS Load Balancer** + **Google-managed SSL cert** — serves your custom domain.
- **Artifact Registry** (`pbfed-images`) — remote mirror of Docker Hub. Cloud Run pulls from here for in-region speed and resilience.
- **Cloud Function + Scheduler** — polls Docker Hub every 5 min. When peerBench publishes a new image, Cloud Run is automatically updated. No GitHub involvement.
- **Service Account** (`pbfed-runner`) — dedicated IAM identity for Cloud Run with minimal permissions.

The node also makes outbound connections to:

- **PDS** (`p.0rs.org` or custom) — identity server used for operator + user sign-in
- **PLC Directory** (`plc.directory`) — DID resolution
- **Federation Indexer** — coordinates the peerBench network

---

## Prerequisites

- A GCP account with billing enabled
- A custom domain you control (you'll add a DNS A record later)
- `gcloud` CLI installed and authenticated
- OpenTofu (or Terraform) installed
- `git` installed

### Installing the tools

**`gcloud` CLI**

- macOS: `brew install --cask google-cloud-sdk`
- Debian/Ubuntu:
  ```bash
  curl https://sdk.cloud.google.com | bash
  exec -l $SHELL
  ```
- Other: <https://cloud.google.com/sdk/docs/install>

After install:
```bash
gcloud auth login
gcloud auth application-default login
```

**OpenTofu**

- macOS: `brew install opentofu`
- Linux:
  ```bash
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh | bash -s -- --install-method standalone
  ```
- Other: <https://opentofu.org/docs/intro/install/>

(Terraform 1.5+ also works in place of OpenTofu — same syntax for everything in this guide.)

**`git`** — usually pre-installed. If not: `brew install git` (macOS) or `sudo apt install git` (Debian/Ubuntu).

### Clone the source

```bash
git clone https://github.com/peerbench/node-deploy.git
cd node-deploy
```

---

## Step 1 — Create GCP Project

```bash
export GCP_PROJECT="pbfed-xxxxxx"        # pick a globally unique project ID
export GCP_REGION="europe-west1"          # pick a region close to you

gcloud projects create $GCP_PROJECT --name="peerBench Federated"
gcloud config set project $GCP_PROJECT

# List billing accounts and link one
gcloud billing accounts list
gcloud billing projects link $GCP_PROJECT --billing-account=<BILLING_ACCOUNT_ID>
```

## Step 2 — Deploy Infrastructure with Terraform

The `terraform/gcp/` directory creates all infrastructure in one apply.

```bash
cd terraform/gcp
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
gcp_project   = "pbfed-xxxxxx"  # your globally-unique project ID
gcp_region    = "europe-west1"
custom_domain = "pbfed.youruniversity.edu"
```

Apply:

```bash
tofu init
tofu plan    # review what will be created
tofu apply
```

Outputs (partial):

```
node_url            = "https://pbfed.youruniversity.edu"
load_balancer_ip    = "34.120.45.67"
storage_bucket_name = "pbfed-xxxxxx-pbfed-storage"
...
```

## Step 3 — Configure DNS

Add an **A record** at your DNS provider:

| Field | Value |
|---|---|
| Type | A |
| Name | `pbfed` (or whatever subdomain matches your `custom_domain`) |
| Value | `load_balancer_ip` from Step 2 output |
| TTL | `auto` (or `300` if your provider needs a number) |

For apex domains, add the A record at root.

After DNS propagates, the Google-managed SSL cert auto-provisions.
**This takes 15-60 minutes** and is unavoidable — it's Google's internal
DNS + CAA verification + cert issuance pipeline, not cert signing time.
Go do something else; check back in ~30 minutes.

Check status:

```bash
gcloud compute ssl-certificates describe pbfed-cert --global \
  --format='value(managed.status)' --project=$GCP_PROJECT
```

Status flow: `PROVISIONING` → `ACTIVE` (ready to use). If you see
`FAILED_NOT_VISIBLE`, DNS isn't resolving to the LB IP yet — verify with
`dig your.domain`.

## Step 4 — Complete the Setup Wizard

1. Open your custom domain in a browser (e.g. `https://pbfed.youruniversity.edu`)
2. You'll see the **Bootstrap Wizard** — runs only on first boot
3. Get the bootstrap token from Cloud Run logs:
   ```bash
   gcloud run services logs read pbfed-node \
     --region=$GCP_REGION --limit=50 --project=$GCP_PROJECT | grep "Bootstrap token"
   ```
4. Get storage credentials for the wizard:
   ```bash
   cd terraform/gcp
   tofu output storage_bucket_name
   tofu output storage_endpoint
   tofu output storage_region
   tofu output storage_access_key_id
   tofu output storage_secret_access_key
   ```
5. Fill in the wizard fields:
   - **Node Public URL**: your custom domain (e.g. `https://pbfed.youruniversity.edu`)
   - **Display Name**: e.g. "MIT peerBench Node"
   - **Login Policy**: `open`, `request-approval`, or `invite-only`
   - **PDS URL**: `https://p.0rs.org` (default)
   - **PLC URL**: `https://plc.directory` (default)
   - **Indexer URL**: `https://indexer.peerbench.ai` (default)
   - **Operator Password**: choose a strong password
   - **Service Account Handle + Email**: a handle for your node's identity
     on the PDS (e.g. `research-lab.bsky.social`)
   - **Storage Bucket / Endpoint / Region / Access Key / Secret**: paste from `tofu output`
6. Complete the wizard. You can now log in as the node operator.

---

## Automatic Updates

Your node polls the `leipniz/pbfed-node` Docker Hub image (temporary location;
will move to `peerbench/pbfed-node` once the official repo is set up) every
5 minutes. When a new version is published, Cloud Run is updated automatically.
You don't need to do anything to receive updates.

---

## Cost Estimate (GCP)

| Resource            | Tier                            | Approx. Monthly Cost          |
| ------------------- | ------------------------------- | ----------------------------- |
| Cloud Run           | 0-1 instances, CPU idle billing | ~$0-5 (may stay in free tier) |
| Cloud SQL           | db-f1-micro, HDD                | ~$8-10                        |
| HTTPS Load Balancer | Forwarding rules + cert         | ~$18                          |
| Artifact Registry   | Image mirror, ~1.2 GB           | ~$0.50                        |
| GCS bucket          | Standard, low usage             | < $1                          |
| Cloud Function      | Scheduler + function invokes    | ~$0 (within free tier)        |
| **Total**           |                                 | **~$30/month**                |

> GCP offers a $300 free trial credit for new accounts.

---

## Troubleshooting

### Node URL shows a "Welcome to Cloud Run" page
The auto-update function hasn't pulled the real image yet. Wait up to 5
minutes (scheduler interval). If still stuck after 10 minutes, trigger the
function manually in the GCP Console
(Cloud Functions → pbfed-auto-update → Testing).

### SSL cert stuck `PROVISIONING`
DNS not yet propagated. Verify with `dig your.domain` — it must resolve to
the LB IP. Provisioning starts once DNS is correct globally.

### "Bootstrap token" not in logs
The token only prints on the first startup. If the wizard was visited once,
the token was consumed. To reset: drop the `node_settings` table in Cloud
SQL and redeploy.

### Cloud SQL connection refused
- Verify Cloud SQL connection name: `$GCP_PROJECT:$GCP_REGION:pbfed-postgres`
- Service account has `roles/cloudsql.client`
- Cloud Run has VPC egress configured (Terraform does this by default)
