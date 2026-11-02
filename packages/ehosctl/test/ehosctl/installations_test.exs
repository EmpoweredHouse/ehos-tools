defmodule Ehosctl.InstallationsTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use Ehosctl.Case, async: false

  alias Ehosctl.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    :ok =
      Config.write(
        %Config{
          current: "local",
          installations: %{
            "local" => %{"url" => "http://ehos.localhost"},
            "staging" => %{"url" => "https://ehos.staging.example.com", "ca" => "pem"}
          }
        },
        dir
      )
  end

  describe "installations list" do
    test "lists the installations, marking the current one", %{tmp_dir: dir} do
      {0, stdout, ""} = ehosctl(["installations", "list"], config_dir: dir)

      assert stdout == """
              CURRENT  NAME     URL                               CA
              *        local    http://ehos.localhost             system
                       staging  https://ehos.staging.example.com  own
             """
    end

    test "lists them as JSON for a script", %{tmp_dir: dir} do
      {0, stdout, ""} = ehosctl(["installations", "list", "--json"], config_dir: dir)

      assert JSON.decode!(stdout) == %{
               "current" => "local",
               "installations" => [
                 %{
                   "name" => "local",
                   "url" => "http://ehos.localhost",
                   "current" => true,
                   "ca" => false
                 },
                 %{
                   "name" => "staging",
                   "url" => "https://ehos.staging.example.com",
                   "current" => false,
                   "ca" => true
                 }
               ]
             }
    end

    test "says so when there are none", %{tmp_dir: dir} do
      assert ehosctl(["installations", "list"], config_dir: Path.join(dir, "empty")) ==
               {0,
                "No installations. An installation shows here after you sign in to it " <>
                  "with `ehosctl login`.\n", ""}
    end

    test "reports a configuration it cannot read as failed, with its own code", %{tmp_dir: dir} do
      File.write!(Config.path(dir), "{not json")

      assert ehosctl(["installations", "list"], config_dir: dir) ==
               {1, "", "ehosctl: #{Config.path(dir)} is not JSON; fix or remove it\n"}
    end

    test "never prints a control character from the configuration to the terminal",
         %{tmp_dir: dir} do
      File.write!(
        Config.path(dir),
        ~s({"version":1,"installations":{"a":{"url":"x\\u001b]0;pwned\\u0007y"}}})
      )

      assert ehosctl(["installations", "list"], config_dir: dir) ==
               {1, "",
                "ehosctl: #{Config.path(dir)} is not an ehosctl configuration; fix or remove it\n"}
    end
  end

  describe "installations use" do
    test "makes one current, and the next list says so", %{tmp_dir: dir} do
      assert ehosctl(["installations", "use", "staging"], config_dir: dir) ==
               {0, "staging is the current installation.\n", ""}

      assert Config.read(dir) ==
               {:ok,
                %Config{
                  current: "staging",
                  installations: %{
                    "local" => %{"url" => "http://ehos.localhost"},
                    "staging" => %{"url" => "https://ehos.staging.example.com", "ca" => "pem"}
                  }
                }}
    end

    test "keeps an installation another command added while it waited", %{tmp_dir: dir} do
      holder = change_config_while_locked(dir, fn -> with_dev(dir) end)

      assert ehosctl(["installations", "use", "staging"], config_dir: dir) ==
               {0, "staging is the current installation.\n", ""}

      assert Task.await(holder) == :ok
      assert Config.read(dir) == {:ok, %{with_dev(dir) | current: "staging"}}
    end

    test "refuses a name it does not know as invalid, and changes nothing", %{tmp_dir: dir} do
      before = File.read!(Config.path(dir))

      assert ehosctl(["installations", "use", "nope"], config_dir: dir) ==
               {2, "", ~s(ehosctl: no installation is named "nope"\n)}

      assert File.read!(Config.path(dir)) == before
    end
  end

  describe "installations use, after a read that failed" do
    test "reads config.json again under its lock", %{tmp_dir: dir} do
      {:ok, config} = Config.read(dir)
      # Half of a file, as a write through a link leaves it for a moment.
      File.write!(Config.path(dir), "{")
      holder = change_config_while_locked(dir, fn -> config end)

      assert ehosctl(["installations", "use", "staging"], config_dir: dir) ==
               {0, "staging is the current installation.\n", ""}

      assert Task.await(holder) == :ok
      assert Config.read(dir) == {:ok, %{config | current: "staging"}}
    end
  end

  describe "installations remove" do
    test "forgets one", %{tmp_dir: dir} do
      {0, stdout, ""} = ehosctl(["installations", "remove", "local", "--json"], config_dir: dir)

      assert JSON.decode!(stdout) == %{"removed" => "local", "current" => nil}

      assert Config.read(dir) ==
               {:ok,
                %Config{
                  current: nil,
                  installations: %{
                    "staging" => %{"url" => "https://ehos.staging.example.com", "ca" => "pem"}
                  }
                }}
    end

    test "keeps an installation another command added while it waited", %{tmp_dir: dir} do
      holder = change_config_while_locked(dir, fn -> with_dev(dir) end)

      assert ehosctl(["installations", "remove", "local"], config_dir: dir) ==
               {0, "ehosctl forgot the installation local.\n", ""}

      assert Task.await(holder) == :ok
      {:ok, config} = Config.read(dir)

      assert config == %Config{
               current: nil,
               installations: %{
                 "dev" => %{"url" => "https://ehos.dev.example.com"},
                 "staging" => %{"url" => "https://ehos.staging.example.com", "ca" => "pem"}
               }
             }
    end

    test "refuses a name it does not know as invalid, and changes nothing", %{tmp_dir: dir} do
      before = File.read!(Config.path(dir))

      assert ehosctl(["installations", "remove", "nope"], config_dir: dir) ==
               {2, "", ~s(ehosctl: no installation is named "nope"\n)}

      assert File.read!(Config.path(dir)) == before
    end
  end

  describe "installations use and remove" do
    test "leave no directory behind for a name they do not know", %{tmp_dir: dir} do
      none = Path.join(dir, "none")

      for command <- ["use", "remove"] do
        assert ehosctl(["installations", command, "nope"], config_dir: none) ==
                 {2, "", ~s(ehosctl: no installation is named "nope"\n)}
      end

      refute File.exists?(none)
    end
  end

  describe "installations" do
    test "prints its help when no subcommand is named", %{tmp_dir: dir} do
      {0, stdout, ""} = ehosctl(["installations"], config_dir: dir)

      assert stdout == """
             ehosctl #{Ehosctl.version()}
             List the installations that this machine knows, and choose the current one.

             USAGE:
                 ehosctl installations

             SUBCOMMANDS:

                 list          List the installations that this machine knows. A * marks the
                               current one.
                 use           Make an installation the current one.
                 remove        Forget an installation. If it was the current one, no
                               installation is current. This does not end its sign-in: run
                               `ehosctl logout` first.

             Plane: local. Works on this machine alone, and needs no EHOS.

             """
    end
  end

  # The configuration as another command would leave it: with `dev` beside what was there.
  defp with_dev(dir) do
    {:ok, config} = Config.read(dir)
    Config.put(config, "dev", "https://ehos.dev.example.com")
  end
end
