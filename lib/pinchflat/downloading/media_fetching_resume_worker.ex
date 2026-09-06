defmodule Pinchflat.Downloading.MediaFetchingResumeWorker do
  @moduledoc """
  Resumes a media fetching queue after it was paused due to a YouTube session
  rate-limit. Runs on the `default` queue so it can execute while the paused queue
  is stopped. Unique so repeated rate-limit hits don't stack multiple resume jobs —
  uniqueness includes the args, so the ordinary and archival queues get one resume each.
  """

  use Oban.Worker,
    queue: :default,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_fetching_resume"]

  require Logger

  @default_queue "media_fetching"

  @doc """
  Schedules a resume of the given queue `seconds` from now.
  """
  def schedule_resume(seconds, queue \\ :media_fetching) do
    %{queue: to_string(queue)}
    |> __MODULE__.new(schedule_in: seconds)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Jobs scheduled before queues were split carry no queue, and those were all for the
    # ordinary queue.
    queue = Map.get(args, "queue", @default_queue)

    Logger.info("Resuming #{queue} queue after rate-limit pause")

    try do
      Oban.resume_queue(queue: String.to_existing_atom(queue), local_only: true)
    rescue
      e -> Logger.error("Could not resume #{queue} queue: #{inspect(e)}")
    end

    :ok
  end
end
