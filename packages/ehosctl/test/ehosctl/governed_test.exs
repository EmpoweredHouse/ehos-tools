defmodule Ehosctl.GovernedTest do
  # What `Ehosctl.CLI` does for every governed command, shown on one that exists only here:
  # it takes `--installation`, and runs only with an installation to talk to (T-07).
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Config

  @moduletag :tmp_dir

  defmodule Whoami do
    @moduledoc false
    @behaviour Ehosctl.Command

    @impl true
    def name, do: :whoami
    @impl true
    def plane, do: :governed
    @impl true
    def spec, do: [about: "Say which installation.", flags: Ehosctl.Output.json_flag()]
    @impl true
    def call([], _parsed, opts) do
      {name, installation} = Keyword.fetch!(opts, :installation)
      {:ok, %{text: "#{name} at #{installation["url"]}", json: %{installation: name}}}
    end
  end

  defmodule People do
    @moduledoc false
    @behaviour Ehosctl.Command

    @impl true
    def name, do: :people
    @impl true
    def plane, do: :governed
    @impl true
    def spec, do: [about: "People.", subcommands: [list: [name: "list", about: "List them."]]]
    @impl true
    def call([:list], _parsed, opts), do: {:ok, %{text: elem(opts[:installation], 0), json: nil}}
  end

  defmodule Apps do
    @moduledoc false
    @behaviour Ehosctl.Command

    @impl true
    def name, do: :apps
    @impl true
    def plane, do: :governed
    @impl true
    def runs_bare?, do: true
    @impl true
    def spec, do: [about: "Apps.", subcommands: [show: [name: "show", about: "Show one."]]]
    @impl true
    def call(path, _parsed, opts),
      do: {:ok, %{text: "#{inspect(path)} #{elem(opts[:installation], 0)}", json: nil}}
  end

  # Say the CA they were handed to trust (T-14): one governed command handed its installation, and
  # one that chooses it itself, as `verify` and `versions` do.
  defmodule Trust do
    @moduledoc false
    @behaviour Ehosctl.Command

    @impl true
    def name, do: :trust
    @impl true
    def plane, do: :governed
    @impl true
    def spec, do: [about: "Say which CA."]
    @impl true
    def call([], _parsed, opts), do: {:ok, %{text: inspect(opts[:ca]), json: nil}}
  end

  defmodule Chooser do
    @moduledoc false
    @behaviour Ehosctl.Command

    @impl true
    def name, do: :chooser
    @impl true
    def plane, do: :governed
    @impl true
    def chooses_installation?, do: true
    @impl true
    def spec, do: [about: "Say which CA."]
    @impl true
    def call([], _parsed, opts), do: {:ok, %{text: inspect(opts[:ca]), json: nil}}
  end

  setup %{tmp_dir: dir} do
    :ok =
      Config.write(
        %Config{
          current: "local",
          installations: %{
            "local" => %{"url" => "u1"},
            "staging" => %{"url" => "u2", "ca" => "staging pem"}
          }
        },
        dir
      )
  end

  describe "a governed command" do
    test "talks to the current installation", %{tmp_dir: dir} do
      assert governed(["whoami"], dir) == {0, "local at u1\n"}
    end

    test "talks to the one --installation names", %{tmp_dir: dir} do
      assert governed(["whoami", "--installation", "staging"], dir) == {0, "staging at u2\n"}
    end

    test "a governed subcommand takes --installation, and its command does not", %{tmp_dir: dir} do
      assert governed(["people", "list", "--installation", "staging"], dir, [People]) ==
               {0, "staging\n"}

      assert governed(["people", "--help"], dir, [People]) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                People.

                USAGE:
                    ehosctl people

                SUBCOMMANDS:

                    list        List them.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """}
    end

    test "a command that runs bare takes --installation itself, as its subcommands do",
         %{tmp_dir: dir} do
      assert governed(["apps"], dir, [Apps]) == {0, "[] local\n"}
      assert governed(["apps", "--installation", "staging"], dir, [Apps]) == {0, "[] staging\n"}

      assert governed(["apps", "show", "--installation", "staging"], dir, [Apps]) ==
               {0, "[:show] staging\n"}
    end

    test "trusts the CA kept for the installation it talks to, and no other's", %{tmp_dir: dir} do
      for command <- [Trust, Chooser] do
        argv = [to_string(command.name())]
        staging = ~s({"staging", "staging pem"}\n)

        assert governed(argv ++ ["--installation", "staging"], dir, [command]) == {0, staging}
        assert governed(argv, dir, [command]) == {0, "nil\n"}
      end
    end

    test "says --installation in its help", %{tmp_dir: dir} do
      assert governed(["whoami", "--help"], dir) ==
               {0,
                """
                ehosctl #{Ehosctl.version()}
                Say which installation.

                USAGE:
                    ehosctl whoami [--json] [--installation NAME]

                FLAGS:

                    --json        Print one JSON document instead of words.

                OPTIONS:

                    --installation        The installation to talk to, instead of
                                          EHOSCTL_INSTALLATION or the current one.

                Plane: governed. This command acts as you, through EHOS. EHOS decides and records each request.

                """}
    end

    test "says on stderr which installation it acts on, when a person reads stderr",
         %{tmp_dir: dir} do
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

      stderr =
        capture_io(:stderr, fn ->
          assert governed(["whoami", "--installation", "staging"], dir) == {0, "staging at u2\n"}
        end)

      assert stderr == "Installation: staging (u2)\n"

      stderr =
        capture_io(:stderr, fn ->
          assert governed(["whoami", "--json"], dir) ==
                   {0, ~s({"installation":"local"}\n)}
        end)

      assert stderr == ""
    end

    test "says nothing of its installation when stderr is not a terminal", %{tmp_dir: dir} do
      assert capture_io(:stderr, fn -> assert {0, _stdout} = governed(["whoami"], dir) end) == ""
    end

    test "says nothing of its installation in CI, at a terminal too", %{tmp_dir: dir} do
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
      stub(Ehosctl.SystemEnvMock, :all, fn -> %{"CI" => "true"} end)

      assert capture_io(:stderr, fn -> assert {0, _stdout} = governed(["whoami"], dir) end) == ""
    end

    test "names an address EHOSCTL_URL gives by the address, not by the variable",
         %{tmp_dir: dir} do
      stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
      stub(Ehosctl.SystemEnvMock, :all, fn -> %{"EHOSCTL_URL" => "https://ehos.ci.example"} end)

      stderr =
        capture_io(:stderr, fn ->
          assert {0, _stdout} = governed(["whoami"], Path.join(dir, "none"))
        end)

      assert stderr == "Installation: https://ehos.ci.example (from EHOSCTL_URL)\n"
    end

    test "a --json after -- is an argument, so the error is in words", %{tmp_dir: dir} do
      stderr =
        capture_io(:stderr, fn -> assert governed(["whoami", "--", "--json"], dir) == {2, ""} end)

      assert stderr == """
             ehosctl: unrecognized arguments: "--json"

             See `ehosctl help whoami`.
             """
    end

    test "does not run without an installation, and exits as not signed in", %{tmp_dir: dir} do
      stderr =
        capture_io(:stderr, fn ->
          assert governed(["whoami", "--installation", "nope"], dir) == {4, ""}
        end)

      assert stderr ==
               ~s(ehosctl: No installation is named "nope". Run `ehosctl installations list` to see the names, or `ehosctl login URL` to sign in to a new installation.\n)

      stderr =
        capture_io(:stderr, fn ->
          assert governed(["whoami", "--json"], Path.join(dir, "none")) == {4, ""}
        end)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "not_signed_in",
                 "message" =>
                   "No installation is current. Run `ehosctl login URL` to sign in to an installation."
               }
             }
    end
  end

  defp governed(argv, dir, commands \\ [Whoami]) do
    capture_io(fn ->
      send(self(), {:code, Ehosctl.CLI.main(argv, commands: commands, config_dir: dir)})
    end)
    |> then(fn stdout -> {receive(do: ({:code, code} -> code)), stdout} end)
  end
end
