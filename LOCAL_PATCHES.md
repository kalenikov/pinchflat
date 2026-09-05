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
- `lib/pinchflat/http/http_client.ex`: add default `:httpc` request/connect
  timeouts, honor `HTTP_PROXY`/`HTTPS_PROXY` with `NO_PROXY`, and safely format
  tuple errors from external YouTube API/RSS calls.
- `lib/pinchflat/downloading/media_download_worker.ex`: on a YouTube session
  rate-limit (`rate-limited` / `try again later`), pause the whole `media_fetching`
  queue for an hour and schedule `MediaFetchingResumeWorker` to resume it, instead of
  burning through the queue mid-ban.
- `lib/pinchflat/downloading/media_downloader.ex` +
  `lib/pinchflat/metadata/metadata_file_helpers.ex`: report thumbnail-download failures
  instead of swallowing them. The thumbnail is a separate yt-dlp call, so a rate-limit
  can hit it right after the media itself downloaded fine. `thumbnail_filepath` would
  then be blank, the metadata changeset invalid, and `download_for_media_item/2` raised
  `CaseClauseError` on the resulting `{:error, changeset}` — which skipped the rate-limit
  handling above entirely and let the queue keep hammering YouTube (every subsequent item
  came back `Video unavailable` and got marked permanently failed). The yt-dlp message now
  travels back to `action_on_error/1`, and a failed save can no longer escape as a raw
  changeset.
- `lib/pinchflat_web/controllers/sources/source_html/media_item_table_live.ex`:
  — Delete+Ignore button (trash icon) on Downloaded tab rows
  — Sortable columns: Title, Upload Date, Duration (with chevron indicators)
  — Duration column showing episode length in H:MM:SS / M:SS format
  — Pagination limit increased from 10 to 100 rows per page
- `lib/pinchflat_web/router.ex` + `.../sources/source_controller.ex` +
  `lib/pinchflat/sources/sources.ex`: add `GET /sources/uuid/:uuid`
  (`show_by_uuid`) that resolves a source uuid to a `302` redirect to the numeric
  `/sources/:id` page. Deeplink target for the KalenikovPod (AntennaPod fork),
  whose only stable per-source identifier is the uuid embedded in the RSS feed URL
  (`/sources/:uuid/feed`).

## Upgrade Checklist

- Before pulling a new upstream Pinchflat version, save `git diff` for the files
  listed above.
- After updating, reapply only the patches still needed for the local runtime.
- Rebuild with `docker compose up -d --build pinchflat`.
- Verify `fast_indexing` jobs complete and that Pinchflat remains healthy.
