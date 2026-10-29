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
               {0, "No installations yet.\n", ""}
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

    test "refuses a name it does not know as invalid, and changes nothing", %{tmp_dir: dir} do
      before = File.read!(Config.path(dir))

      assert ehosctl(["installations", "use", "nope"], config_dir: dir) ==
               {2, "", ~s(ehosctl: no installation is named "nope"\n)}

      assert File.read!(Config.path(dir)) == before
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

    test "refuses a name it does not know as invalid, and changes nothing", %{tmp_dir: dir} do
      before = File.read!(Config.path(dir))

      assert ehosctl(["installations", "remove", "nope"], config_dir: dir) ==
               {2, "", ~s(ehosctl: no installation is named "nope"\n)}

      assert File.read!(Config.path(dir)) == before
    end
  end

  describe "installations" do
    test "prints its help when no subcommand is named", %{tmp_dir: dir} do
      {0, stdout, ""} = ehosctl(["installations"], config_dir: dir)

      assert stdout == """
             ehosctl #{Ehosctl.version()}
             List the installations you know, and choose the current one.

             USAGE:
                 ehosctl installations

             SUBCOMMANDS:

                 list          List the installations you know, marking the current one.
                 use           Make an installation the current one.
                 remove        Forget an installation. None is current if it was. Its sign-in
                               is not ended: run `ehosctl logout` first.

             Plane: local. Works on this machine alone, and needs no EHOS.

             """
    end
  end
end
