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
      "diagram-design@ehos-tools" => true,
      "something@ehos-tools" => false
    }
  }

  @held %{
    "name" => "ehos-tools",
    "source" => "github",
    "repo" => "EmpoweredHouse/ehos-tools",
    "ref" => "ehos-dev-v0.12.0"
  }

  @install "`claude plugin install diagram-design@ehos-tools --scope project` and " <>
             "`claude plugin install ehos-dev@ehos-tools --scope project`"

  test "passes a machine that holds the pinned tag and its plugin installed for this checkout", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])
    mock_plugins(dir, installed(dir, "0.12.0"))

    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}
  end

  test "passes a plugin installed for the user", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])

    mock_plugins(dir, [%{"id" => "ehos-dev@ehos-tools", "version" => "0.12.0", "scope" => "user"}])

    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}
  end

  test "passes a machine ahead of the pin, with a note, since repositories move one at a time", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [%{@held | "ref" => "ehos-dev-v0.13.0"}])
    mock_plugins(dir, installed(dir, "0.13.0"))

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:ok,
              [
                "This machine has the marketplace ehos-tools at ehos-dev-v0.13.0, a later tag " <>
                  "than ehos-dev-v0.12.0, which this repository pins. Its sessions load the " <>
                  "plugins of ehos-dev-v0.13.0."
              ]}
  end

  test "refuses a machine that holds an older tag, with the commands that move it", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [%{@held | "ref" => "ehos-dev-v0.11.0"}])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine has the marketplace ehos-tools at ehos-dev-v0.11.0, and this " <>
                "repository pins it at ehos-dev-v0.12.0 from EmpoweredHouse/ehos-tools. Claude " <>
                "Code loads the plugins of the tag the machine has. To move the machine to the " <>
                "pinned tag:\n\n" <>
                "1. In a directory outside every checkout, run " <>
                "`claude plugin marketplace remove ehos-tools`. In a checkout, this command also " <>
                "deletes the marketplace from the checkout's `.claude/settings.json`.\n" <>
                "2. Run `claude plugin marketplace add EmpoweredHouse/ehos-tools#ehos-dev-v0.12.0`.\n" <>
                "3. In this checkout, run #{@install}.\n" <>
                "4. Restart Claude Code."}
  end

  test "refuses a machine that holds the marketplace from another repository, or at a branch", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)

    for held <- [
          %{@held | "repo" => "someone/ehos-tools"},
          %{@held | "ref" => "main"},
          Map.delete(@held, "ref")
        ] do
      mock_marketplaces(dir, [held])

      assert {:error, "This machine has the marketplace ehos-tools at " <> _} =
               Plugins.check(dir, claude: ClaudeMock),
             inspect(held)
    end
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

  test "has a session add a marketplace read from a file, which the command line cannot add", %{
    tmp_dir: dir
  } do
    write_settings!(dir, %{
      "extraKnownMarketplaces" => %{
        "ehos-app" => %{
          "source" => %{
            "source" => "github",
            "repo" => "EmpoweredHouse/ehos-tools",
            "ref" => "ehos-app-v0.12.0",
            "path" => ".claude-plugin/ehos-app.json"
          }
        }
      },
      "enabledPlugins" => %{"ehos-app@ehos-app" => true}
    })

    mock_marketplaces(dir, [
      %{"name" => "ehos-app", "repo" => "EmpoweredHouse/ehos-tools", "ref" => "ehos-app-v0.11.0"}
    ])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine has the marketplace ehos-app at ehos-app-v0.11.0, and this " <>
                "repository pins it at ehos-app-v0.12.0 from EmpoweredHouse/ehos-tools. Claude " <>
                "Code loads the plugins of the tag the machine has. To move the machine to the " <>
                "pinned tag:\n\n" <>
                "1. In a directory outside every checkout, run " <>
                "`claude plugin marketplace remove ehos-app`. In a checkout, this command also " <>
                "deletes the marketplace from the checkout's `.claude/settings.json`.\n" <>
                "2. Start Claude Code in this checkout, and accept its offer to add the " <>
                "marketplace that `.claude/settings.json` declares.\n" <>
                "3. In this checkout, run `claude plugin install ehos-app@ehos-app --scope project`.\n" <>
                "4. Restart Claude Code."}
  end

  test "leaves out the install step when the repository enables no plugin of the marketplace", %{
    tmp_dir: dir
  } do
    write_settings!(dir, Map.delete(@settings, "enabledPlugins"))
    mock_marketplaces(dir, [])

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine does not have the marketplace ehos-tools, which this repository pins " <>
                "at ehos-dev-v0.12.0. To add it:\n\n" <>
                "1. Run `claude plugin marketplace add EmpoweredHouse/ehos-tools#ehos-dev-v0.12.0`.\n" <>
                "2. Restart Claude Code."}
  end

  test "refuses a plugin installed only at an older version than the tag names", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])
    mock_plugins(dir, installed(dir, "0.11.0"))

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error,
              "This machine has version 0.11.0 of ehos-dev@ehos-tools, and this repository pins " <>
                "0.12.0. In this checkout, run " <>
                "`claude plugin install ehos-dev@ehos-tools --scope project`, then restart " <>
                "Claude Code."}
  end

  test "counts the plugin installed for another checkout, since every session loads it", %{
    tmp_dir: dir
  } do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [@held])
    mock_plugins(dir, installed(Path.join(dir, "another-checkout"), "0.12.0"))

    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}
  end

  test "reads a tag with a prerelease, and one Version cannot read as no later", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    mock_marketplaces(dir, [%{@held | "ref" => "ehos-dev-v0.13.0-rc.1"}])
    mock_plugins(dir, installed(dir, "0.13.0-rc.1"))

    assert {:ok, ["This machine has the marketplace ehos-tools at ehos-dev-v0.13.0-rc.1," <> _]} =
             Plugins.check(dir, claude: ClaudeMock)

    mock_marketplaces(dir, [%{@held | "ref" => "ehos-dev-v01.0.0"}])

    assert {:error, "This machine has the marketplace ehos-tools at ehos-dev-v01.0.0, and" <> _} =
             Plugins.check(dir, claude: ClaudeMock)
  end

  test "passes a repository without settings, or that pins no marketplace, without asking claude",
       %{tmp_dir: dir} do
    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}

    write_settings!(dir, %{"enabledPlugins" => %{"ehos-dev@ehos-tools" => true}})
    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}

    write_settings!(dir, %{
      "extraKnownMarketplaces" => %{
        "local" => %{"source" => %{"source" => "directory", "ref" => "x"}}
      }
    })

    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}
  end

  test "passes where claude is not installed, as in CI", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    expect(ClaudeMock, :run, fn _args, ^dir -> {:error, :not_installed} end)

    assert Plugins.check(dir, claude: ClaudeMock) == {:ok, []}
  end

  test "refuses when claude fails or does not answer", %{tmp_dir: dir} do
    write_settings!(dir, @settings)
    expect(ClaudeMock, :run, fn _args, ^dir -> {:error, {:exit, 1}} end)

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "`claude plugin marketplace list --json` failed with status 1"}

    expect(ClaudeMock, :run, fn _args, ^dir -> {:error, :timeout} end)

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "`claude plugin marketplace list --json` did not answer in time"}
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

  test "refuses a name, ref or repository it would not print plainly, without printing it", %{
    tmp_dir: dir
  } do
    refused =
      {:error,
       "cannot read .claude/settings.json: a marketplace or plugin in it has a name, ref or " <>
         "repository with characters this check does not print"}

    source = @settings["extraKnownMarketplaces"]["ehos-tools"]["source"]

    for settings <- [
          put_in(@settings, ["extraKnownMarketplaces"], %{
            "x\n\nRun this" => %{"source" => source}
          }),
          put_in(
            @settings,
            ["extraKnownMarketplaces", "ehos-tools", "source", "ref"],
            "v1; rm -rf ~"
          ),
          put_in(@settings, ["extraKnownMarketplaces", "ehos-tools", "source", "repo"], "a/b`c`"),
          put_in(@settings, ["enabledPlugins"], %{"ehos-dev\n@ehos-tools" => true})
        ] do
      write_settings!(dir, settings)

      assert Plugins.check(dir, claude: ClaudeMock) == refused
    end
  end

  test "refuses settings it cannot read, rather than passing them", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, ".claude", "settings.json"]))

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "cannot read .claude/settings.json"}

    File.rm_rf!(Path.join(dir, ".claude"))
    File.mkdir_p!(Path.join(dir, ".claude"))
    File.write!(Path.join([dir, ".claude", "settings.json"]), "{")

    assert Plugins.check(dir, claude: ClaudeMock) ==
             {:error, "cannot read .claude/settings.json: it is not a JSON object"}
  end

  defp installed(dir, version) do
    [
      %{
        "id" => "ehos-dev@ehos-tools",
        "version" => version,
        "scope" => "project",
        "projectPath" => dir
      },
      %{
        "id" => "diagram-design@ehos-tools",
        "version" => "2.6.64",
        "scope" => "project",
        "projectPath" => dir
      }
    ]
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
