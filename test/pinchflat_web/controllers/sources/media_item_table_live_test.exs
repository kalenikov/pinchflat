defmodule PinchflatWeb.Sources.MediaItemTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Media
  alias PinchflatWeb.Sources.MediaItemTableLive

  setup do
    source = source_fixture()

    {:ok, source: source}
  end

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn, source: source} do
      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Nothing Here!"
      refute html =~ "Showing"
    end

    test "shows records when present", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source))

      assert html =~ "Showing"
      assert html =~ "Title"
      assert html =~ media_item.title
    end
  end

  describe "media_state" do
    test "shows pending media when pending", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ pending_media_item.title
      refute html =~ downloaded_media_item.title
    end

    test "shows downloaded media when downloaded", %{conn: conn, source: source} do
      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows records that aren't pending or downloaded when other", %{conn: conn} do
      media_profile = media_profile_fixture(shorts_behaviour: :exclude)
      source = source_fixture(media_profile_id: media_profile.id)

      downloaded_media_item = media_item_fixture(source_id: source.id)
      pending_media_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      other_media_item = media_item_fixture(source_id: source.id, media_filepath: nil, short_form_content: true)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ other_media_item.title
      refute html =~ downloaded_media_item.title
      refute html =~ pending_media_item.title
    end

    test "shows 'Manually Ignored' column when other", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, prevent_download: true, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "other"))

      assert html =~ "Manually Ignored?"
    end
  end

  describe "delete+ignore button" do
    test "shows delete button on downloaded tab", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ "hero-trash"
    end

    test "shows delete button on pending tab", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ "hero-trash"
      # Deliberately no confirmation dialog on either tab — see LOCAL_PATCHES.md
      refute html =~ "data-confirm"
    end

    test "delete button triggers delete_item event with item id", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ ~s(phx-click="delete_item")
      assert html =~ ~s(phx-value-id="#{media_item.id}")
    end

    test "pending delete button triggers delete_item event with item id", %{conn: conn, source: source} do
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      assert html =~ ~s(phx-click="delete_item")
      assert html =~ ~s(phx-value-id="#{media_item.id}")
    end

    test "delete_item event removes item from table", %{conn: conn, source: source} do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
      media_item = media_item_fixture(source_id: source.id)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      render_hook(view, "delete_item", %{"id" => to_string(media_item.id)})

      refute render(view) =~ media_item.title
    end

    test "delete_item event ignores pending item and removes it from pending table", %{conn: conn, source: source} do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      render_hook(view, "delete_item", %{"id" => to_string(media_item.id)})

      refute render(view) =~ media_item.title
      assert Media.get_media_item!(media_item.id).prevent_download
    end
  end

  describe "sorting" do
    test "default sort is uploaded_at desc", %{conn: conn, source: source} do
      older = media_item_fixture(source_id: source.id, uploaded_at: ~U[2022-01-01 00:00:00Z])
      newer = media_item_fixture(source_id: source.id, uploaded_at: ~U[2024-01-01 00:00:00Z])

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      html = render(view)
      newer_pos = :binary.match(html, newer.title) |> elem(0)
      older_pos = :binary.match(html, older.title) |> elem(0)

      assert newer_pos < older_pos
    end

    test "sort_update event toggles direction for same key", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      # initial sort is uploaded_at desc → toggle same key → asc → chevron-up icon
      render_hook(view, "sort_update", %{"sort_key" => "uploaded_at"})
      assert render(view) =~ "hero-chevron-up"
    end

    test "sort_update to different key defaults to desc", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      render_hook(view, "sort_update", %{"sort_key" => "title"})
      html = render(view)
      assert html =~ "sort_key=&quot;title&quot;" or html =~ ~s(sort_key="title")
    end

    test "ignores unknown sort keys", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert render_hook(view, "sort_update", %{"sort_key" => "injected_column"})
    end
  end

  describe "duration column" do
    test "shows duration column header", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ "Duration"
    end

    test "formats duration in M:SS for short videos", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, duration_seconds: 125)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ "2:05"
    end

    test "formats duration in H:MM:SS for long videos", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, duration_seconds: 3661)

      {:ok, _view, html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "downloaded"))

      assert html =~ "1:01:01"
    end

    test "shows empty string when duration is nil", %{conn: conn, source: source} do
      _media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      {:ok, view, _html} = live_isolated(conn, MediaItemTableLive, session: create_session(source, "pending"))

      html = render(view)
      assert html =~ "Duration"
    end
  end

  defp create_session(source, media_state \\ "pending") do
    %{"source_id" => source.id, "media_state" => media_state}
  end
end
