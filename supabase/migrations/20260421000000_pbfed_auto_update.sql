-- pbfed auto-update: state table + pg_cron schedule
--
-- The agent replaces {{FUNCTION_URL}} and {{ANON_KEY}} with real values
-- immediately before running `supabase db push`. See
-- `docs/deploy-render-supabase.md` Step X for the substitution command.
--
-- FUNCTION_URL format: https://<project-ref>.functions.supabase.co/pbfed-auto-update
-- ANON_KEY comes from `supabase projects api-keys --project-ref <ref>`
--   (the "anon" row — NOT service_role; the Edge Function gets service_role
--    injected automatically at runtime).

CREATE TABLE IF NOT EXISTS pbfed_auto_update (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Drop any prior schedule under the same name so re-running this migration
-- on an existing project is idempotent.
SELECT cron.unschedule('pbfed-auto-update')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'pbfed-auto-update'
);

SELECT cron.schedule(
  'pbfed-auto-update',
  '*/5 * * * *',
  $cron$
    SELECT net.http_post(
      url := '{{FUNCTION_URL}}',
      headers := jsonb_build_object(
        'Authorization', 'Bearer {{ANON_KEY}}',
        'Content-Type', 'application/json'
      ),
      body := '{}'::jsonb
    );
  $cron$
);
