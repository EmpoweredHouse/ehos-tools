defmodule EhosApp.CodexPluginsTest do
  use ExUnit.Case, async: true
  import Hammox
  alias EhosApp.CodexFixture, as: Fixture
  alias EhosApp.CodexPlugins

  setup :verify_on_exit!
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".codex"))
    File.write!(Path.join(dir, ".codex/config.toml"), CodexPlugins.config())
    %{dir: dir}
  end

  test "accepts enabled native plugins from clean checkouts at the pinned commits", %{dir: dir} do
    Fixture.mock_check()
    assert CodexPlugins.check(dir, command: EhosApp.CommandMock) == {:ok, []}
  end

  test "setup invokes Codex's own marketplace and plugin installers before checking", %{dir: dir} do
    for pin <- CodexPlugins.pins() do
      expect(EhosApp.CommandMock, :run, fn "codex",
                                           ["plugin", "marketplace", "upgrade", name, "--json"],
                                           ^dir ->
        assert name == pin.marketplace
        {:ok, "{}"}
      end)

      expect(EhosApp.CommandMock, :run, fn "codex", ["plugin", "add", id, "--json"], ^dir ->
        assert id == "#{pin.name}@#{pin.marketplace}"
        {:ok, "{}"}
      end)
    end

    Fixture.mock_check()
    assert CodexPlugins.setup(dir, command: EhosApp.CommandMock) == {:ok, []}
  end

  test "refuses missing, disabled, stale and differently sourced installed plugins", %{dir: dir} do
    [first | rest] = Fixture.installed()

    for installed <- [
          rest,
          [Map.put(first, "enabled", false) | rest],
          [Map.put(first, "installed", false) | rest],
          [Map.put(first, "version", "0.1.0") | rest],
          [
            Map.put(first, "marketplaceSource", %{"sourceType" => "local", "source" => "other"})
            | rest
          ],
          [nil]
        ] do
      expect(EhosApp.CommandMock, :run, fn "codex",
                                           [
                                             "plugin",
                                             "list",
                                             "--marketplace",
                                             _marketplace,
                                             "--json"
                                           ],
                                           ^dir ->
        {:ok, JSON.encode!(%{"installed" => installed})}
      end)

      assert {:error, message} = CodexPlugins.check(dir, command: EhosApp.CommandMock)
      assert message =~ "Cannot verify the pinned Codex plugins"
    end
  end

  test "refuses stale or dirty marketplace checkouts", %{dir: dir} do
    for revision <- ["older", "dirty"] do
      Fixture.mock_check()

      expect(EhosApp.CommandMock, :run, 2, fn "codex",
                                              [
                                                "plugin",
                                                "list",
                                                "--marketplace",
                                                _marketplace,
                                                "--json"
                                              ],
                                              ^dir ->
        {:ok, JSON.encode!(%{"installed" => Fixture.installed()})}
      end)

      expect(EhosApp.CommandMock, :run, fn "codex",
                                           ["plugin", "marketplace", "list", "--json"],
                                           ^dir ->
        {:ok, JSON.encode!(%{"marketplaces" => Fixture.marketplaces()})}
      end)

      expect(EhosApp.CommandMock, :run, fn "git", ["rev-parse", "HEAD"], _root ->
        {:ok, if(revision == "dirty", do: hd(CodexPlugins.pins()).commit, else: revision)}
      end)

      if revision == "dirty" do
        expect(EhosApp.CommandMock, :run, fn "git",
                                             [
                                               "status",
                                               "--porcelain",
                                               "--untracked-files=all",
                                               "--",
                                               ".",
                                               ":(exclude).codex-marketplace-install.json"
                                             ],
                                             _root ->
          {:ok, " M plugins/ehos-app/skills/ship/SKILL.md\n"}
        end)
      end

      assert {:error, _message} = CodexPlugins.check(dir, command: EhosApp.CommandMock)
    end
  end

  test "refuses missing or differently sourced marketplaces", %{dir: dir} do
    for marketplaces <- [[], [%{"name" => "ehos-tools", "root" => "other"}], [nil]] do
      Fixture.mock_check()

      expect(EhosApp.CommandMock, :run, 2, fn "codex",
                                              [
                                                "plugin",
                                                "list",
                                                "--marketplace",
                                                _marketplace,
                                                "--json"
                                              ],
                                              ^dir ->
        {:ok, JSON.encode!(%{"installed" => Fixture.installed()})}
      end)

      expect(EhosApp.CommandMock, :run, fn "codex",
                                           ["plugin", "marketplace", "list", "--json"],
                                           ^dir ->
        {:ok, JSON.encode!(%{"marketplaces" => marketplaces})}
      end)

      assert {:error, _message} = CodexPlugins.check(dir, command: EhosApp.CommandMock)
    end
  end

  test "fails closed for missing Codex, command failures and unreadable answers", %{dir: dir} do
    for answer <- [
          {:error, :not_installed},
          {:error, :timeout},
          {:error, {:exit, 1}},
          {:ok, "secret invalid output"},
          {:ok, "[]"},
          {:ok, "null"}
        ] do
      expect(EhosApp.CommandMock, :run, fn "codex",
                                           [
                                             "plugin",
                                             "list",
                                             "--marketplace",
                                             _marketplace,
                                             "--json"
                                           ],
                                           ^dir ->
        answer
      end)

      assert {:error, message} = CodexPlugins.check(dir, command: EhosApp.CommandMock)
      refute message =~ "secret"
    end
  end

  test "stops setup after a failed refresh", %{dir: dir} do
    expect(EhosApp.CommandMock, :run, fn "codex",
                                         ["plugin", "marketplace", "upgrade", _, "--json"],
                                         ^dir ->
      {:error, {:exit, 1}}
    end)

    assert {:error, _message} = CodexPlugins.setup(dir, command: EhosApp.CommandMock)
  end

  test "requires project configuration before asking Codex", %{dir: dir} do
    File.rm!(Path.join(dir, ".codex/config.toml"))
    expect(EhosApp.CommandMock, :run, 0, fn _, _, _ -> {:ok, ""} end)
    assert {:error, _message} = CodexPlugins.setup(dir, command: EhosApp.CommandMock)
    assert {:error, _message} = CodexPlugins.check(dir, command: EhosApp.CommandMock)
  end

  test "the application marketplace exposes only the shared application plugin" do
    root = Path.expand("../../../..", __DIR__)
    read = fn path -> root |> Path.join(path) |> File.read!() |> JSON.decode!() end

    assert %{"name" => "ehos-app", "plugins" => [entry]} =
             read.(".agents/plugins/marketplace.json")

    assert entry in read.(".claude-plugin/ehos-app.json")["plugins"]

    assert entry["source"] ==
             Enum.find(
               read.(".claude-plugin/marketplace.json")["plugins"],
               &(&1["name"] == "ehos-app")
             )["source"]
  end

  test "configures the shared pins and the original plugin names" do
    for pin <- CodexPlugins.pins() do
      assert CodexPlugins.config() =~ ~s(ref = "#{pin.commit}")
      assert CodexPlugins.config() =~ ~s([plugins."#{pin.name}@#{pin.marketplace}"])
    end

    for skill <- ["ship", "review"] do
      root = Path.expand("../../../../plugins/ehos-app/skills", __DIR__)

      assert File.read!(Path.join([root, skill, "agents/openai.yaml"])) ==
               "policy:\n  allow_implicit_invocation: false\n"

      assert File.read!(Path.join([root, skill, "SKILL.md"])) =~ "disable-model-invocation: true"
    end
  end
end
