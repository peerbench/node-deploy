// Supabase Edge Function: pbfed-auto-update
//
// Purpose: polled every 5 minutes by a pg_cron job in the same project.
// Compares the current Docker Hub digest of the pbfed-node image against the
// last-known digest stored in `pbfed_auto_update`. On change, triggers a
// Render redeploy via the REST API. Updates the stored digest only on a
// successful deploy POST.
//
// Invoked via `net.http_post` from a pg_cron job — no user-facing auth. The
// function uses the SUPABASE_SERVICE_ROLE_KEY that the Edge Function runtime
// injects automatically.
//
// Required secrets (set via `supabase secrets set` during deploy):
//   - RENDER_API_KEY       Render personal API key with deploy scope
//   - RENDER_SERVICE_ID    e.g. srv-abc123
//
// Optional secrets (defaults are fine for most deploys):
//   - IMAGE_REPO           Docker Hub repo, default "leipniz/pbfed-node"
//   - IMAGE_TAG            Tag to track, default "latest"
//
// Query params:
//   - force=1              Skip digest comparison, always trigger redeploy.
//                          Useful for smoke-testing the Render POST without
//                          waiting for a new image.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RENDER_API_KEY = Deno.env.get("RENDER_API_KEY");
const RENDER_SERVICE_ID = Deno.env.get("RENDER_SERVICE_ID");
const IMAGE_REPO = Deno.env.get("IMAGE_REPO") ?? "leipniz/pbfed-node";
const IMAGE_TAG = Deno.env.get("IMAGE_TAG") ?? "latest";

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (!RENDER_API_KEY || !RENDER_SERVICE_ID) {
    return json(500, {
      ok: false,
      error: "missing_secrets",
      detail:
        "RENDER_API_KEY and RENDER_SERVICE_ID must be set via `supabase secrets set`.",
    });
  }

  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";

  // 1. Fetch current digest from Docker Hub.
  const hubRes = await fetch(
    `https://hub.docker.com/v2/repositories/${IMAGE_REPO}/tags/${IMAGE_TAG}`
  );
  if (!hubRes.ok) {
    return json(502, {
      ok: false,
      error: "docker_hub_failed",
      status: hubRes.status,
    });
  }
  const hubData = (await hubRes.json()) as {
    digest?: string;
    images?: Array<{ digest?: string }>;
  };
  const currentDigest = hubData.digest ?? hubData.images?.[0]?.digest ?? null;
  if (!currentDigest) {
    return json(502, { ok: false, error: "no_digest_in_response" });
  }

  // 2. Compare to stored digest.
  const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: row } = await db
    .from("pbfed_auto_update")
    .select("value")
    .eq("key", "last_digest")
    .maybeSingle();
  const lastDigest = row?.value ?? null;

  if (!force && lastDigest === currentDigest) {
    return json(200, {
      ok: true,
      status: "no_change",
      digest: currentDigest,
    });
  }

  // 3. Trigger Render redeploy.
  const deployRes = await fetch(
    `https://api.render.com/v1/services/${RENDER_SERVICE_ID}/deploys`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RENDER_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ clearCache: "do_not_clear" }),
    }
  );
  if (!deployRes.ok) {
    const errText = await deployRes.text();
    return json(502, {
      ok: false,
      error: "render_deploy_failed",
      status: deployRes.status,
      detail: errText,
    });
  }

  // 4. Record the new digest so the next tick sees "no change".
  const { error: upsertErr } = await db.from("pbfed_auto_update").upsert({
    key: "last_digest",
    value: currentDigest,
    updated_at: new Date().toISOString(),
  });
  if (upsertErr) {
    // Non-fatal: the deploy already fired. Next tick may re-trigger.
    return json(200, {
      ok: true,
      status: "deploy_triggered_but_upsert_failed",
      digest: currentDigest,
      upsert_error: upsertErr.message,
    });
  }

  return json(200, {
    ok: true,
    status: "deploy_triggered",
    previous_digest: lastDigest,
    new_digest: currentDigest,
  });
});
