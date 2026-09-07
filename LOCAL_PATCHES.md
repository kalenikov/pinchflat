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
- **Archival mode** (`archival_mode` / `archival_sleep_seconds` on `sources`, migration
  `20260905120000`): a per-source switch for pulling a channel's whole back catalogue
  without ever putting the YouTube account in front of the crawl.
  - `lib/pinchflat/sources/sources.ex`: `use_cookies?/2` checks archival mode *before*
    everything else, so neither the source's own `cookie_behaviour` nor
    `PINCHFLAT_FORCE_COOKIES` can put cookies back in. Only `:error_recovery` gets them —
    one retry for a video anonymous access can't reach (age-gated, members-only).
    `archival_sleep_seconds/1` (base 180s) and `slow_down_archival_pace/1` (doubling,
    ceiling 3600s) hold the pace.
  - `lib/pinchflat/yt_dlp/command_runner.ex`: `sleep_interval_override` in `addl_opts`
    beats the global `extractor_sleep_interval_seconds`, including when it is 0.
    `skip_sleep_interval` still wins over both.
  - `lib/pinchflat/downloading/media_downloader.ex` +
    `lib/pinchflat/metadata/metadata_file_helpers.ex`: pass the source's pace to all three
    per-video yt-dlp calls — downloadable check, download, thumbnail.
  - `lib/pinchflat/downloading/media_download_worker.ex`: on a rate-limit, an archival
    source's pace doubles permanently. One-way by design — nothing speeds a source back
    up except the user turning the mode off, which resets the pace via the changeset.
  - Indexing is untouched: it is one request for a whole channel, not a series, and its
    sleeps are deliberately skipped upstream (`skip_sleep_interval: true`).
  - Depth still comes from `download_cutoff_date` as usual; archival mode changes pace and
    cookies only.
  - Base pace is empirical: 2026-09-04 saw 17 back-to-back downloads at ~4.6 min spacing
    with no rate-limit, while ~40s spacing got the session banned on the fifth request the
    next day.
- `lib/pinchflat/downloading/media_download_worker.ex`: the permanent-failure list also
  matches YouTube's **Russian** wording. `base-config.txt` pins `youtube:lang=ru,ru-RU`, so
  YouTube's own text is localised while yt-dlp's added hints stay English. An unrecognised
  permanent failure looks retryable, and Oban then burns all 20 attempts with an alert on
  each — a members-only video ("Станьте спонсором…") did exactly that on 2026-09-07.
  The rate-limit branch was already safe: its "rate-limited" hint comes from yt-dlp itself.
- **Archival mode, part two — pacing and its own queue** (`config/runtime.exs`,
  `media_download_worker.ex`, `media_fetching_resume_worker.ex`, `media_downloader.ex`,
  `metadata_file_helpers.ex`, `download_option_builder.ex`, `sources.ex`):
  - new Oban queue `media_fetching_archival`. On the shared queue one archival item held up
    every ordinary channel for half an hour, and its 28-34 minutes in `executing` also
    tripped the sync-service watchdog (30 min threshold) — four false "Queue stalled"
    alerts in a day. Routing happens in `MediaDownloadWorker.kickoff_with_task/3`, the one
    point every enqueue path goes through.
  - the rate-limit pause and `MediaFetchingResumeWorker` now act on the queue that hit the
    limit, not always `media_fetching`. Archival downloads run anonymously, ordinary ones
    with the account's cookies, so a ban on one session says nothing about the other.
  - **the pause moved to where it belongs: between videos, not between requests.** One video
    costs up to three yt-dlp runs, and a per-request pause multiplied out to ~28 minutes per
    video. Now per-request pacing is a flat 10s (`archival_request_sleep_seconds`) and the
    worker holds `archival_sleep_seconds` after finishing a job — on a sequential queue that
    is exactly the gap between downloads. Expect ~5-6 min/video.
  - two of the three YouTube round-trips per video removed: the thumbnail is copied from
    the file the download already wrote (`DownloadOptionBuilder.thumbnail_location_for/1`)
    instead of being fetched again, and the live-status check is skipped for archival
    sources' videos older than a day that aren't flagged as livestreams.
  - toggling archival mode moves a source's queued jobs between queues (Oban's uniqueness
    includes the queue, so they would otherwise duplicate or run at the old pace).
  - **rollback if bans appear:** put the full pace back in `Sources.archival_pace_opts/1`
    (one line). The removed round-trips can stay — they only lower the risk.
- `lib/pinchflat_web/controllers/sources/source_html/media_item_table_live.ex`:
  — Delete+Ignore button (trash icon) on Downloaded and Pending tab rows,
    with no confirmation dialog on either tab (`data-confirm` intentionally absent)
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
