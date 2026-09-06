defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Downloading.MediaDownloader

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    # Routing lives here rather than in the callers so every path that queues a download —
    # indexing, the pending-download button, a manual force, a quality upgrade — lands in
    # the right lane without each having to know about archival mode.
    source = Repo.preload(media_item, :source).source
    job_opts = Keyword.put_new(job_opts, :queue, Sources.download_queue_for(source))

    %{id: media_item.id}
    |> Map.merge(job_args)
    |> MediaDownloadWorker.new(job_opts)
    |> Tasks.create_job_with_task(media_item)
  end

  @doc """
  For a given media item, download the media alongside any options.
  Does not download media if its source is set to not download media
  (unless forced).

  Options:
    - `force`: force download even if the source is set to not download media. Fully
      re-downloads media, including the video
    - `quality_upgrade?`: re-downloads media, including the video. Does not force download
      if the source is set to not download media

  Returns :ok | {:error, any, ...any}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => media_item_id} = args, queue: queue}) do
    should_force = Map.get(args, "force", false)
    is_quality_upgrade = Map.get(args, "quality_upgrade?", false)

    media_item = fetch_and_run_prevent_download_user_script(media_item_id)

    result =
      if should_download_media?(media_item, should_force, is_quality_upgrade) do
        download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, queue)
      else
        :ok
      end

    pace_archival_source(media_item, result)

    result
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")
  end

  # If this is a quality upgrade, only check if the source is set to download media
  # or that the media item's download hasn't been prevented
  defp should_download_media?(media_item, should_force, true = _is_quality_upgrade) do
    (media_item.source.download_media && !media_item.prevent_download) || should_force
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download
  defp should_download_media?(media_item, should_force, _is_quality_upgrade) do
    source = media_item.source
    is_pending = Media.pending_download?(media_item)

    (is_pending && source.download_media && !media_item.prevent_download) || should_force
  end

  # If a user script exists and, when run, returns a non-zero exit code, prevent this and all future downloads
  # of the media item.
  defp fetch_and_run_prevent_download_user_script(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    {:ok, media_item} =
      case run_user_script(:media_pre_download, media_item) do
        {:ok, _, exit_code} when exit_code != 0 -> Media.update_media_item(media_item, %{prevent_download: true})
        _ -> {:ok, media_item}
      end

    Repo.preload(media_item, :source)
  end

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, queue) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites
    override_opts = [overwrite_behaviour: overwrite_behaviour]

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        {:ok, updated_media_item} =
          Media.update_media_item(downloaded_media_item, %{
            media_size_bytes: compute_media_filesize(downloaded_media_item),
            media_redownloaded_at: get_redownloaded_at(is_quality_upgrade)
          })

        :ok = FileSyncing.delete_outdated_files(media_item, updated_media_item)
        run_user_script(:media_downloaded, updated_media_item)

        :ok

      {:recovered, _media_item, _message} ->
        {:error, :retry}

      {:error, :unsuitable_for_download, _message} ->
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        action_on_error(message, media_item, queue)
    end
  end

  defp compute_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp get_redownloaded_at(true), do: DateTime.utc_now()
  defp get_redownloaded_at(_), do: nil

  # Pause the media_fetching queue for this long when YouTube rate-limits the session.
  @rate_limit_pause_seconds 60 * 60

  defp action_on_error(message, media_item, queue) do
    msg = to_string(message)

    # This will attempt re-download at the next indexing, but it won't be retried
    # immediately as part of job failure logic
    non_retryable_errors = [
      "Video unavailable",
      "Sign in to confirm",
      "This video is available to this channel's members"
    ]

    # YouTube rate-limit errors also contain "Video unavailable", so this must be
    # checked FIRST — otherwise they'd be misclassified as permanent per-video failures.
    rate_limit_errors = [
      "rate-limited",
      "try again later"
    ]

    cond do
      String.contains?(msg, rate_limit_errors) ->
        pause_media_fetching_for_rate_limit(message, queue)
        slow_down_archival_source(media_item)
        # Snooze this item so it is retried once the queue resumes.
        {:snooze, @rate_limit_pause_seconds}

      String.contains?(msg, non_retryable_errors) ->
        Logger.error("yt-dlp download will not be retried: #{inspect(message)}")
        {:ok, :non_retry}

      true ->
        {:error, :download_failed}
    end
  end

  # The archival pace is the gap BETWEEN videos, and this queue runs one job at a time —
  # so holding the worker here, after the work is done, is that gap. Waiting afterwards
  # rather than beforehand keeps the spacing honest even when a download fails.
  #
  # Skipped for a rate-limited job: its queue is already paused for an hour, and snoozing
  # is the fast path back into that pause.
  defp pace_archival_source(_media_item, {:snooze, _}), do: :ok

  defp pace_archival_source(media_item, _result) do
    source = Repo.preload(media_item, :source).source

    case Sources.archival_sleep_seconds(source) do
      nil ->
        :ok

      seconds ->
        Logger.info("Archival source ##{source.id}: waiting #{seconds}s before the next download")
        pacer = Application.get_env(:pinchflat, :archival_pacer, &Process.sleep/1)
        pacer.(seconds * 1000)
    end
  end

  # An archival source just found out its current pace is too fast for YouTube today, so
  # it permanently backs off. The hourly queue pause above only buys time; without this
  # the crawl would resume at exactly the pace that just got it banned.
  defp slow_down_archival_source(media_item) do
    source = Repo.preload(media_item, :source).source

    case Sources.slow_down_archival_pace(source) do
      {:ok, %{archival_mode: true} = slowed} ->
        Logger.warning("Archival source ##{slowed.id} slowed to #{slowed.archival_sleep_seconds}s between requests")

      _ ->
        :ok
    end
  end

  # The session behind this queue is rate-limited, so pausing just this job is pointless —
  # every other download queued on it would hit the same wall. Pause that queue and
  # schedule a resume once the (roughly one hour) limit has passed.
  #
  # Only the queue that hit the limit is paused: archival downloads run anonymously while
  # ordinary ones use the account's cookies, so a ban on one session says nothing about
  # the other.
  defp pause_media_fetching_for_rate_limit(message, queue) do
    queue_atom = queue_to_atom(queue)

    Logger.warning(
      "YouTube session rate-limited; pausing #{queue} for #{@rate_limit_pause_seconds}s. Message: #{inspect(message)}"
    )

    try do
      Oban.pause_queue(queue: queue_atom, local_only: true)
    rescue
      e -> Logger.error("Could not pause #{queue} queue: #{inspect(e)}")
    end

    Pinchflat.Downloading.MediaFetchingResumeWorker.schedule_resume(@rate_limit_pause_seconds, queue_atom)
  end

  # Oban hands the queue back as a string; every queue we could be running on is declared
  # in config, so the atom is guaranteed to exist already.
  defp queue_to_atom(queue) when is_atom(queue), do: queue
  defp queue_to_atom(queue) when is_binary(queue), do: String.to_existing_atom(queue)

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
