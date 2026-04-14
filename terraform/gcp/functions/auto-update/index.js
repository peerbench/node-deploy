import functions from "@google-cloud/functions-framework";
import { google } from "googleapis";

// --- Config from env vars set by Terraform on the Cloud Function ---
const PROJECT = process.env.PROJECT;
const REGION = process.env.REGION;
const SERVICE_NAME = process.env.SERVICE_NAME;
// IMAGE_HUB_REPO: where we poll for the latest digest (Docker Hub)
// IMAGE_AR_REPO: where Cloud Run pulls from (AR remote mirror, faster + cached)
const IMAGE_HUB_REPO = process.env.IMAGE_HUB_REPO; // e.g. "docker.io/peerbench/pbfed-node"
const IMAGE_AR_REPO = process.env.IMAGE_AR_REPO; // e.g. "europe-west1-docker.pkg.dev/proj/pbfed-images/peerbench/pbfed-node"
const IMAGE_TAG = process.env.IMAGE_TAG || "latest";

// HTTP function invoked by Cloud Scheduler every 5 minutes.
// Flow: check Docker Hub digest -> compare to Cloud Run -> patch via AR URL if different.
functions.http("checkAndUpdate", async (req, res) => {
  try {
    // 1. Fetch current :latest digest from Docker Hub
    const hubDigest = await fetchRegistryDigest(IMAGE_HUB_REPO, IMAGE_TAG);
    if (!hubDigest) {
      return res.status(500).send("Could not fetch registry digest");
    }

    // 2. Read Cloud Run service to get the image currently deployed
    const run = google.run({
      version: "v2",
      auth: new google.auth.GoogleAuth({
        scopes: ["https://www.googleapis.com/auth/cloud-platform"],
      }),
    });

    const serviceName = `projects/${PROJECT}/locations/${REGION}/services/${SERVICE_NAME}`;
    const { data: service } = await run.projects.locations.services.get({
      name: serviceName,
    });

    // Image URI may be pinned like "repo@sha256:xxx" or tag-only like "repo:latest".
    // We only care about the digest part (after @). If there's no digest, force update.
    const currentImage = service.template?.containers?.[0]?.image ?? "";
    const currentDigest = currentImage.includes("@")
      ? currentImage.split("@")[1]
      : null;

    // 3. No-op if already on the latest digest
    if (currentDigest === hubDigest) {
      return res.status(200).send(`No change (digest ${hubDigest})`);
    }

    // 4. Patch Cloud Run with the new digest using the AR mirror URL.
    //    AR proxies Docker Hub transparently — same image content,
    //    but cached in-region for faster cold starts and isolated from
    //    Docker Hub rate limits / outages.
    //
    //    Send the full template back with just the image swapped, and use
    //    updateMask=template (no subfield filter). Partial PATCH on nested
    //    template subfields (e.g. updateMask=template.containers) drops
    //    sibling fields like volumes and volume_mounts on Cloud Run v2.
    const newImage = `${IMAGE_AR_REPO}@${hubDigest}`;
    const updatedTemplate = {
      ...service.template,
      containers: service.template.containers.map((c, i) =>
        i === 0 ? { ...c, image: newImage } : c
      ),
    };

    await run.projects.locations.services.patch({
      name: serviceName,
      updateMask: "template",
      requestBody: {
        template: updatedTemplate,
      },
    });

    return res
      .status(200)
      .send(`Updated ${SERVICE_NAME} to ${hubDigest}`);
  } catch (err) {
    console.error(err);
    return res.status(500).send(`Error: ${err.message}`);
  }
});

// Fetches the Docker-Content-Digest header from the OCI registry manifest endpoint.
// We poll Docker Hub directly (not AR) because AR caches the digest until pulled,
// so we always get the freshest "what's published upstream" answer from Docker Hub.
async function fetchRegistryDigest(repo, tag) {
  // Strip "docker.io/" prefix since the API host is registry-1.docker.io
  const repoName = repo.replace(/^docker\.io\//, "");
  const registry = repo.startsWith("docker.io/")
    ? "https://registry-1.docker.io"
    : `https://${repo.split("/")[0]}`;

  // Anonymous pull token for Docker Hub public repos
  const tokenRes = await fetch(
    `https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repoName}:pull`
  );
  const { token } = await tokenRes.json();

  // Manifest request returns digest in the Docker-Content-Digest response header.
  const manifestRes = await fetch(
    `${registry}/v2/${repoName}/manifests/${tag}`,
    {
      headers: {
        Accept:
          "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json",
        Authorization: `Bearer ${token}`,
      },
    }
  );

  return manifestRes.headers.get("docker-content-digest");
}
