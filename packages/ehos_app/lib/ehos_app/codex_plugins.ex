defmodule EhosApp.CodexPlugins do
  @moduledoc """
  Configures and verifies the native Codex marketplaces used by generated applications.

  The project enables the original plugins at pinned commits. Setup uses Codex's own installer;
  review checks the installed versions, enabled state, source repositories and checkout commits.
  It never consults Claude's cache or copies skills into the application.
  """

  @failure "Cannot verify the pinned Codex plugins. Trust this project in Codex, reconcile " <>
             ".codex/config.toml with this installer's pins, run mix ehos_app.codex.setup, " <>
             "and restart the session before review."

  @doc "Returns the shared pins with the names of their native Codex marketplaces."
  @spec pins() :: [map()]
  defdelegate pins(), to: EhosApp.PluginPins, as: :all

  @doc "Returns project configuration for the pinned Git marketplaces and enabled plugins."
  @spec config() :: String.t()
  def config do
    "# EHOS plugin settings. Keep your other Codex settings when updating these pins.\n\n" <>
      Enum.map_join(pins(), "\n", fn pin ->
        """
        [marketplaces.#{pin.marketplace}]
        source_type = "git"
        source = "https://github.com/#{pin.repo}.git"
        ref = "#{pin.commit}"

        [plugins."#{pin.name}@#{pin.marketplace}"]
        enabled = true
        """
      end)
  end

  @doc """
  Installs the configured plugins with Codex and verifies the result.

  Run in a trusted project with its `.codex/config.toml`. `opts[:command]` selects an
  `EhosApp.Command`, defaulting to `EhosApp.CommandImpl`. Failures never include subprocess output.
  """
  @spec setup(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def setup(dir, opts \\ []) do
    command = Keyword.get(opts, :command, EhosApp.CommandImpl)

    with :ok <- configured(dir),
         :ok <- install_all(command, dir) do
      check(dir, opts)
    end
  end

  @doc """
  Verifies that the expected plugin versions are enabled and their marketplaces have the pinned commits.

  Missing Codex, malformed answers, different repositories, missing or disabled plugins, stale versions,
  and dirty or stale marketplace checkouts refuse review. `opts[:command]` selects `EhosApp.Command`.
  The installed version is Codex's reported version, not a signature of locally modified cache files.
  """
  @spec check(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def check(dir, opts \\ []) do
    command = Keyword.get(opts, :command, EhosApp.CommandImpl)

    with :ok <- configured(dir),
         true <- Enum.all?(pins(), &installed_at?(&1, command, dir)),
         {:ok, %{"marketplaces" => marketplaces}} when is_list(marketplaces) <-
           ask(command, ["plugin", "marketplace", "list", "--json"], dir),
         true <- Enum.all?(pins(), &held?(&1, marketplaces, command)) do
      {:ok, []}
    else
      _failure -> {:error, @failure}
    end
  end

  defp configured(dir) do
    if File.regular?(Path.join(dir, ".codex/config.toml")), do: :ok, else: {:error, @failure}
  end

  defp install_all(command, dir) do
    Enum.reduce_while(pins(), :ok, fn pin, :ok ->
      with {:ok, _output} <-
             command.run(
               "codex",
               ["plugin", "marketplace", "upgrade", pin.marketplace, "--json"],
               dir
             ),
           {:ok, _output} <-
             command.run(
               "codex",
               ["plugin", "add", "#{pin.name}@#{pin.marketplace}", "--json"],
               dir
             ) do
        {:cont, :ok}
      else
        _failure -> {:halt, {:error, @failure}}
      end
    end)
  end

  defp ask(command, args, dir) do
    with {:ok, output} <- command.run("codex", args, dir), do: JSON.decode(output)
  end

  # Filtering avoids contacting unrelated remote plugin catalogs during a local review.
  defp installed_at?(pin, command, dir) do
    case ask(command, ["plugin", "list", "--marketplace", pin.marketplace, "--json"], dir) do
      {:ok, %{"installed" => installed}} when is_list(installed) -> installed?(pin, installed)
      _failure -> false
    end
  end

  defp installed?(pin, installed) do
    Enum.any?(installed, fn
      %{"pluginId" => id, "version" => version, "installed" => true, "enabled" => true} = plugin ->
        id == "#{pin.name}@#{pin.marketplace}" and version == pin.version and source?(plugin, pin)

      _other ->
        false
    end)
  end

  defp source?(%{"marketplaceSource" => %{"sourceType" => "git", "source" => source}}, pin),
    do: source == "https://github.com/#{pin.repo}.git"

  defp source?(_entry, _pin), do: false

  defp held?(pin, marketplaces, command) do
    entry = Enum.find(marketplaces, &(is_map(&1) and &1["name"] == pin.marketplace))
    checkout?(entry, pin, command)
  end

  # Codex writes its own install record into the checkout; every other untracked file counts.
  defp checkout?(%{"root" => root} = entry, pin, command) when is_binary(root) do
    with true <- source?(entry, pin),
         {:ok, revision} <- command.run("git", ["rev-parse", "HEAD"], root),
         true <- String.trim(revision) == pin.commit,
         {:ok, ""} <-
           command.run(
             "git",
             [
               "status",
               "--porcelain",
               "--untracked-files=all",
               "--",
               ".",
               ":(exclude).codex-marketplace-install.json"
             ],
             root
           ) do
      true
    else
      _failure -> false
    end
  end

  defp checkout?(_entry, _pin, _command), do: false
end
