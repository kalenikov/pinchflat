defmodule Pinchflat.Repo.Migrations.AddArchivalModeToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :archival_mode, :boolean, null: false, default: false
      add :archival_sleep_seconds, :integer
    end
  end
end
