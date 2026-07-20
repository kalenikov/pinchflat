defmodule Pinchflat.Downloading.MediaFetchingResumeWorker do
  @moduledoc """
  Resumes the `media_fetching` queue after it was paused due to a YouTube session
  rate-limit. Runs on the `default` queue so it can execute while `media_fetching`
  is paused. Unique so repeated rate-limit hits don't stack multiple resume jobs.
  """

  use Oban.Worker,
    queue: :default,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_fetching_resume"]

  require Logger

  @doc """
  Schedules a resume of the `media_fetching` queue `seconds` from now.
  """
  def schedule_resume(seconds) do
    %{}
    |> __MODULE__.new(schedule_in: seconds)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Resuming media_fetching queue after rate-limit pause")

    try do
      Oban.resume_queue(queue: :media_fetching, local_only: true)
    rescue
      e -> Logger.error("Could not resume media_fetching queue: #{inspect(e)}")
    end

    :ok
  end
end
