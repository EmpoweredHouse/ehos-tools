defmodule Mix.Tasks.EhosApp.Codex.Setup do
  @moduledoc """
  Installs the project's pinned native Codex marketplace plugins.

  Trust the application in Codex first, then run `mix ehos_app.codex.setup` from its root.
  Codex must be installed and Git must have access to the private marketplace repositories.
  Restart the Codex session after setup. This installs plugins into Codex's own cache and
  leaves Claude's configuration and the application's skills untouched.
  """
  use Mix.Task

  @shortdoc "Installs and verifies the pinned native Codex plugins"

  @doc false
  @impl Mix.Task
  def run([]) do
    case EhosApp.CodexPlugins.setup(".") do
      {:ok, _notes} ->
        Mix.shell().info("Codex plugins are installed at the pinned releases. Restart Codex.")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix ehos_app.codex.setup")
end
