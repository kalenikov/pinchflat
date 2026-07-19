defmodule PinchflatWeb.Sources.MediaItemTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Media
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Utils.NumberUtils

  @limit 100
  @valid_sort_keys ~w(uploaded_at title duration_seconds)

  def render(%{total_record_count: 0} = assigns) do
    ~H"""
    <div class="mb-4 flex items-center">
      <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" />
      <p class="ml-2">Nothing Here!</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <header class="flex justify-between items-center mb-4">
        <span class="flex items-center">
          <.icon_button icon_name="hero-arrow-path" class="h-10 w-10" phx-click="reload_page" tooltip="Refresh" />
          <span class="mx-2">
            Showing <.localized_number number={length(@records)} /> of <.localized_number number={@filtered_record_count} />
          </span>
        </span>
        <div class="bg-meta-4 rounded-md">
          <div class="relative">
            <span class="absolute left-2 top-1/2 -translate-y-1/2 flex">
              <.icon name="hero-magnifying-glass" />
            </span>
            <form phx-change="search_term" phx-submit="search_term">
              <input
                type="text"
                name="q"
                value={@search_term}
                placeholder="Search in table..."
                class="w-full bg-transparent pl-9 pr-4 border-0 focus:ring-0 focus:outline-none"
                phx-debounce="200"
              />
            </form>
          </div>
        </div>
      </header>
      <.table rows={@records} table_class="text-white" sort_key={@sort_key} sort_direction={@sort_direction}>
        <:col :let={media_item} label="Title" sort_key="title" class="max-w-xs">
          <section class="flex items-center space-x-1">
            <.tooltip
              :if={media_item.last_error}
              tooltip={media_item.last_error}
              position="bottom-right"
              tooltip_class="w-64"
            >
              <.icon name="hero-exclamation-circle-solid" class="text-red-500" />
            </.tooltip>
            <span class="truncate">
              <.subtle_link href={~p"/sources/#{@source.id}/media/#{media_item.id}"}>
                {media_item.title}
              </.subtle_link>
            </span>
          </section>
        </:col>
        <:col :let={media_item} :if={@media_state == "other"} label="Manually Ignored?">
          <.icon name={if media_item.prevent_download, do: "hero-check", else: "hero-x-mark"} />
        </:col>
        <:col :let={media_item} label="Upload Date" sort_key="uploaded_at">
          {DateTime.to_date(media_item.uploaded_at)}
        </:col>
        <:col :let={media_item} label="Duration" sort_key="duration_seconds">
          {format_duration(media_item.duration_seconds)}
        </:col>
        <:col :let={media_item} label="" class="flex justify-end">
          <.link
            :if={show_ignore_button?(@media_state)}
            phx-click="delete_item"
            phx-value-id={media_item.id}
            data-confirm={ignore_confirmation(@media_state)}
            class="mr-4 text-red-400 hover:text-red-300 cursor-pointer"
          >
            <.icon name="hero-trash" class="w-5 h-5" />
          </.link>
          <.icon_link href={~p"/sources/#{@source.id}/media/#{media_item.id}/edit"} icon="hero-pencil-square" />
        </:col>
      </.table>
      <section class="flex justify-center mt-5">
        <.live_pagination_controls page_number={@page} total_pages={@total_pages} />
      </section>
    </div>
    """
  end

  def mount(_params, session, socket) do
    PinchflatWeb.Endpoint.subscribe("media_table")

    page = 1
    media_state = session["media_state"]
    source = Sources.get_source!(session["source_id"])
    base_query = generate_base_query(source, media_state)
    sort_key = "uploaded_at"
    sort_direction = "desc"
    pagination_attrs = fetch_pagination_attributes(base_query, page, nil, sort_key, sort_direction)

    new_assigns =
      Map.merge(
        pagination_attrs,
        %{
          base_query: base_query,
          source: source,
          media_state: media_state,
          sort_key: sort_key,
          sort_direction: sort_direction
        }
      )

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("sort_update", %{"sort_key" => sort_key}, %{assigns: assigns} = socket) do
    sort_direction =
      if assigns.sort_key == sort_key and assigns.sort_direction == "desc", do: "asc", else: "desc"

    new_assigns = fetch_pagination_attributes(assigns.base_query, 1, assigns.search_term, sort_key, sort_direction)

    {:noreply, assign(socket, Map.merge(new_assigns, %{sort_key: sort_key, sort_direction: sort_direction}))}
  end

  def handle_event("page_change", %{"direction" => direction}, %{assigns: assigns} = socket) do
    direction = if direction == "inc", do: 1, else: -1
    new_page = assigns.page + direction
    new_assigns = fetch_pagination_attributes(assigns.base_query, new_page, assigns.search_term, assigns.sort_key, assigns.sort_direction)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("search_term", params, socket) do
    search_term = Map.get(params, "q", nil)
    new_assigns = fetch_pagination_attributes(socket.assigns.base_query, 1, search_term, socket.assigns.sort_key, socket.assigns.sort_direction)

    {:noreply, assign(socket, new_assigns)}
  end

  def handle_event("delete_item", %{"id" => id}, %{assigns: assigns} = socket) do
    media_item = Media.get_media_item!(String.to_integer(id))
    {:ok, _} = Media.delete_media_files(media_item, %{prevent_download: true})
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, assigns.sort_key, assigns.sort_direction)

    {:noreply, assign(socket, new_assigns)}
  end

  # This, along with the handle_info below, is a pattern to reload _all_
  # tables on page rather than just the one that triggered the reload.
  def handle_event("reload_page", _params, socket) do
    PinchflatWeb.Endpoint.broadcast("media_table", "reload", nil)

    {:noreply, socket}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, %{assigns: assigns} = socket) do
    new_assigns = fetch_pagination_attributes(assigns.base_query, assigns.page, assigns.search_term, assigns.sort_key, assigns.sort_direction)

    {:noreply, assign(socket, new_assigns)}
  end

  defp fetch_pagination_attributes(base_query, page, "", sort_key, sort_direction),
    do: fetch_pagination_attributes(base_query, page, nil, sort_key, sort_direction)

  defp fetch_pagination_attributes(base_query, page, nil, sort_key, sort_direction) do
    total_record_count = Repo.aggregate(base_query, :count, :id)
    total_pages = max(ceil(total_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    {sort_dir, sort_col} = sort_order(sort_key, sort_direction)

    records =
      fetch_records(base_query, page)
      |> order_by([{^sort_dir, ^sort_col}])
      |> Repo.all()

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: nil,
      total_record_count: total_record_count,
      filtered_record_count: total_record_count
    }
  end

  defp fetch_pagination_attributes(base_query, page, search_term, sort_key, sort_direction) do
    filtered_base_query = filtered_base_query(base_query, search_term)

    total_record_count = Repo.aggregate(base_query, :count, :id)
    filtered_record_count = Repo.aggregate(filtered_base_query, :count, :id)
    total_pages = max(ceil(filtered_record_count / @limit), 1)
    page = NumberUtils.clamp(page, 1, total_pages)

    {sort_dir, sort_col} = sort_order(sort_key, sort_direction)

    records =
      fetch_records(filtered_base_query, page)
      |> order_by([{:desc, fragment("rank")}, {^sort_dir, ^sort_col}])
      |> Repo.all()

    %{
      page: page,
      total_pages: total_pages,
      records: records,
      search_term: search_term,
      total_record_count: total_record_count,
      filtered_record_count: filtered_record_count
    }
  end

  defp fetch_records(base_query, page) do
    offset = (page - 1) * @limit

    base_query
    |> limit(^@limit)
    |> offset(^offset)
  end

  defp generate_base_query(source, "pending") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
  end

  defp generate_base_query(source, "downloaded") do
    MediaQuery.new()
    |> select(^select_fields())
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
  end

  defp generate_base_query(source, "other") do
    MediaQuery.new()
    |> select(^select_fields())
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        ^MediaQuery.for_source(source) and
          (not (^MediaQuery.downloaded()) and not (^MediaQuery.pending()))
      )
    )
  end

  defp generate_base_query(source, "ignored") do
    MediaQuery.new()
    |> select(^select_fields())
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.download_prevented()))
  end

  defp filtered_base_query(base_query, search_term) do
    base_query
    |> MediaQuery.require_assoc(:media_items_search_index)
    |> where(^MediaQuery.matches_search_term(search_term))
  end

  defp sort_order(sort_key, sort_direction) do
    key = if sort_key in @valid_sort_keys, do: String.to_existing_atom(sort_key), else: :uploaded_at
    dir = if sort_direction == "asc", do: :asc, else: :desc
    {dir, key}
  end

  defp format_duration(nil), do: ""

  defp format_duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    if h > 0,
      do: :io_lib.format(~c"~B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary(),
      else: :io_lib.format(~c"~B:~2..0B", [m, s]) |> IO.iodata_to_binary()
  end

  defp show_ignore_button?(media_state), do: media_state in ["downloaded", "pending"]

  defp ignore_confirmation("pending"), do: nil
  defp ignore_confirmation(_media_state), do: "Delete files and prevent re-download?"

  # Selecting only what we need GREATLY speeds up queries on large tables
  defp select_fields do
    [:id, :title, :uploaded_at, :prevent_download, :last_error, :duration_seconds]
  end
end
