# Local Pinchflat Patches

This Pinchflat checkout is built locally by `docker-compose.yaml` as
`pinchflat-local:v2025.9.26-no-sources-pagination`. Keep this file updated when
changing upstream Pinchflat code so future upgrades can reapply or drop local
patches deliberately.

## Active Patches

- `docker/selfhosted.Dockerfile`: use Node.js 24 and make selected network-heavy
  build/update steps best-effort with timeouts.
- `lib/pinchflat/sources/sources.ex`: support `PINCHFLAT_FORCE_COOKIES=1` to
  force cookie use for all source operations.
- `lib/pinchflat/yt_dlp/command_runner.ex`: support `PINCHFLAT_YT_DLP_JS_RUNTIMES`,
  `PINCHFLAT_YT_DLP_REMOTE_COMPONENTS`, and
  `PINCHFLAT_YT_DLP_IGNORE_NO_FORMATS_ERROR`.
- `lib/pinchflat_web/controllers/sources/...`: remove sources table pagination
  for the local UI build.
- `lib/pinchflat/http/http_client.ex`: add default `:httpc` request and connect
  timeouts so external YouTube API/RSS calls cannot occupy Oban workers forever.

## Upgrade Checklist

- Before pulling a new upstream Pinchflat version, save `git diff` for the files
  listed above.
- After updating, reapply only the patches still needed for the local runtime.
- Rebuild with `docker compose up -d --build pinchflat`.
- Verify `fast_indexing` jobs complete and that Pinchflat remains healthy.
