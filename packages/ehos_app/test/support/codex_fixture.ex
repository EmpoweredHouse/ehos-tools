defmodule EhosApp.CodexFixture do
  @moduledoc false

  def installed do
    for pin <- EhosApp.CodexPlugins.pins() do
      %{
        "pluginId" => "#{pin.name}@#{pin.marketplace}",
        "version" => pin.version,
        "installed" => true,
        "enabled" => true,
        "marketplaceSource" => source(pin)
      }
    end
  end

  def marketplaces do
    for pin <- EhosApp.CodexPlugins.pins() do
      %{"name" => pin.marketplace, "root" => pin.marketplace, "marketplaceSource" => source(pin)}
    end
  end

  def mock_check do
    Hammox.stub(EhosApp.CommandMock, :run, fn
      "codex", ["plugin", "list", "--marketplace", _marketplace, "--json"], _dir ->
        {:ok, JSON.encode!(%{"installed" => installed()})}

      "codex", ["plugin", "marketplace", "list", "--json"], _dir ->
        {:ok, JSON.encode!(%{"marketplaces" => marketplaces()})}

      "git", ["rev-parse", "HEAD"], dir ->
        {:ok, Enum.find(EhosApp.CodexPlugins.pins(), &(&1.marketplace == dir)).commit <> "\n"}

      "git",
      [
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
        ".",
        ":(exclude).codex-marketplace-install.json"
      ],
      _dir ->
        {:ok, ""}
    end)
  end

  defp source(pin), do: %{"sourceType" => "git", "source" => "https://github.com/#{pin.repo}.git"}
end
