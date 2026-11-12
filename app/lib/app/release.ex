defmodule App.Release do
  @moduledoc """
  Release tasks for running database migrations.
  """

  @app :app

  def migrate do
    load_app()
    Ecto.Migrator.with_repo(App.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  def rollback(repo, version) do
    load_app()
    Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp load_app do
    Application.load(@app)
  end
end
