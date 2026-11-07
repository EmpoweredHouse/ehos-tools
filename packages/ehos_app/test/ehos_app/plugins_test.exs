defmodule EhosApp.PluginsTest do
  use ExUnit.Case, async: true

  import Hammox

  alias EhosApp.ClaudeMock
  alias EhosApp.Plugins

  setup :verify_on_exit!

  @moduletag :tmp_dir

  @settings %{
    "extraKnownMarketplaces" => %{
      "ehos-tools" => %{
        "source" => %{
          "source" => "github",
          "repo" => "EmpoweredHouse/ehos-tools",
          "ref" => "ehos-dev-v0.12.0"
        }
      }
    },
    "enabledPlugins" => %{
      "ehos-dev@ehos-tools" => true,
      "diagram-design@ehos-tools" => true
    }
  }

  @held %{
    "name" => "ehos-tools",
    "source" => "github",
    "repo" => "EmpoweredHouse/ehos-tools",
    "ref" => "ehos-dev-v0.12.0"
  }

  @installed [
    %{"id" => "ehos-dev@ehos-tools", "version" => "0.12.0"},
    %{"id" => "diagram-design@ehos-tools", "version" => "2.6.64"}
  ]

  @install "`claude plugin install diagram-design@ehos-tools --scope project` and " <>
             "`claude plugin install ehos-dev@ehos-tools --scope project`"

  test "passes when the machine holds the pinned tag and its plugin at the tag's version", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])
    mock_plugins(dir, @installed)

    assert Plugins.check(dir, claude: ClaudeMock) == :ok
  end

  test "refuses a machine that holds another tag of the marketplace, with the commands that move it",
       %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [%{@held | "ref" => "ehos-dev-v0.11.0"}])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine has the marketplace ehos-tools at ehos-dev-v0.11.0, and this " <>
                "repository pins it at ehos-dev-v0.12.0. Claude Code loads the plugins of the " <>
                "tag the machine has. To move the machine to the pinned tag:\n\n" <>
                "1. In a directory outside every checkout, run " <>
                "`claude plugin marketplace remove ehos-tools`. In a checkout, this command also " <>
                "deletes the marketplace from the checkout's `.claude/settings.json`.\n" <>
                "2. Run `claude plugin marketplace add EmpoweredHouse/ehos-tools#ehos-dev-v0.12.0`.\n" <>
                "3. In this checkout, run #{@install}.\n" <>
                "4. Restart Claude Code."}
  end

  test "refuses a machine that holds the marketplace from another repository", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [%{@held | "repo" => "someone/ehos-tools"}])

    assert {:error, "This machine has the marketplace ehos-tools at ehos-dev-v0.12.0, and" <> _} =
             Plugins.check(dir, claude: ClaudeMock)
  end

  test "refuses a machine that holds the marketplace at its default branch", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [Map.delete(@held, "ref")])

    assert {:error,
            "This machine has the marketplace ehos-tools at its default branch, and this " <> _} =
             Plugins.check(dir, claude: ClaudeMock)
  end

  test "refuses a machine without the marketplace, with the commands that add it", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine does not have the marketplace ehos-tools, which this repository pins " <>
                "at ehos-dev-v0.12.0. To add it:\n\n" <>
                "1. Run `claude plugin marketplace add EmpoweredHouse/ehos-tools#ehos-dev-v0.12.0`.\n" <>
                "2. In this checkout, run #{@install}.\n" <>
                "3. Restart Claude Code."}
  end

  test "refuses a plugin installed at another version than the tag names", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])

    mock_plugins(dir, [
      %{"id" => "ehos-dev@ehos-tools", "version" => "0.11.0"},
      %{"id" => "diagram-design@ehos-tools", "version" => "2.6.64"}
    ])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine has version 0.11.0 of ehos-dev@ehos-tools, and this repository pins " <>
                "0.12.0. In this checkout, run " <>
                "`claude plugin install ehos-dev@ehos-tools --scope project`, then restart " <>
                "Claude Code."}
  end

  test "refuses a plugin that is not installed", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])
    mock_plugins(dir, [])

    assert {:error, "This machine has no version of ehos-dev@ehos-tools, and" <> _} =
             Plugins.check(dir, claude: ClaudeMock)
  end

  test "passes a repository without settings, or that pins no marketplace, without asking claude",
       %{tmp_dir: dir} do
    assert Plugins.check(dir, claude: ClaudeMock) == :ok

    write_settings!(dir, %{"enabledPlugins" => %{"ehos-dev@ehos-tools" => true}})
    assert Plugins.check(dir, claude: ClaudeMock) == :ok
  end

  test "passes where claude is not installed, as in CI", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    expect(ClaudeMock, :run, fn _args, ^dir -> {:error, :not_installed} end)

    assert Plugins.check(dir, claude: ClaudeMock) == :ok
  end

  test "refuses when claude fails", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    expect(ClaudeMock, :run, fn _args, ^dir -> {:error, {:exit, 1}} end)

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "`claude plugin marketplace list --json` failed with status 1"}
  end

  test "refuses an answer whose shape it cannot read, rather than passing it", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    expect(ClaudeMock, :run, fn _args, ^dir -> {:ok, ~s({"marketplaces": []})} end)

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "`claude plugin marketplace list --json` answered in a shape this check cannot " <>
                "read. Check the marketplaces and plugins by hand with " <>
                "`claude plugin marketplace list` and `claude plugin list`."}
  end

  test "refuses settings that are not JSON", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".claude"))
    File.write!(Path.join([dir, ".claude", "settings.json"]), "{")

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "cannot read .claude/settings.json: it is not a JSON object"}
  end

  defp write_settings!(dir, settings) do
    File.mkdir_p!(Path.join(dir, ".claude"))
    File.write!(Path.join([dir, ".claude", "settings.json"]), JSON.encode!(settings))
  end

  defp mock_marketplaces(dir, held) do
    expect(ClaudeMock, :run, fn ["plugin", "marketplace", "list", "--json"], ^dir ->
      {:ok, JSON.encode!(held)}
    end)
  end

  defp mock_plugins(dir, installed) do
    expect(ClaudeMock, :run, fn ["plugin", "list", "--json"], ^dir ->
      {:ok, JSON.encode!(installed)}
    end)
  end
end
