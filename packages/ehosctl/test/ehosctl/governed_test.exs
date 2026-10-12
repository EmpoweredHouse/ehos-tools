defmodule Ehosctl.GovernedTest do
  # What `Ehosctl.CLI` does for every governed command, shown on one that exists only here:
  # it takes `--installation`, and runs only with an installation to talk to (T-07).
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use ExUnit.Case, async: false

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

  defp ehosctl(argv, dir, commands \\ [Whoami]) do
    capture_io(fn ->
      send(self(), {:code, Ehosctl.CLI.main(argv, commands: commands, config_dir: dir)})
    end)
    |> then(fn stdout -> {receive(do: ({:code, code} -> code)), stdout} end)
  end

  test "talks to the current installation", %{tmp_dir: dir} do
    assert ehosctl(["whoami"], dir) == {0, "local at u1\n"}
  end

  test "talks to the one --installation names", %{tmp_dir: dir} do
    assert ehosctl(["whoami", "--installation", "staging"], dir) == {0, "staging at u2\n"}
  end

  test "a governed subcommand takes --installation, and its command does not", %{tmp_dir: dir} do
    assert ehosctl(["people", "list", "--installation", "staging"], dir, [People]) ==
             {0, "staging\n"}

    {0, help} = ehosctl(["people", "--help"], dir, [People])
    refute help =~ "--installation"
  end

  test "a command that runs bare takes --installation itself, as its subcommands do",
       %{tmp_dir: dir} do
    assert ehosctl(["apps"], dir, [Apps]) == {0, "[] local\n"}
    assert ehosctl(["apps", "--installation", "staging"], dir, [Apps]) == {0, "[] staging\n"}

    assert ehosctl(["apps", "show", "--installation", "staging"], dir, [Apps]) ==
             {0, "[:show] staging\n"}
  end

  test "trusts the CA kept for the installation it talks to, and no other's", %{tmp_dir: dir} do
    for command <- [Trust, Chooser] do
      argv = [to_string(command.name())]
      staging = ~s({"staging", "staging pem"}\n)

      assert ehosctl(argv ++ ["--installation", "staging"], dir, [command]) == {0, staging}
      assert ehosctl(argv, dir, [command]) == {0, "nil\n"}
    end
  end

  test "a --json after -- is an argument, so the error is in words", %{tmp_dir: dir} do
    stderr =
      capture_io(:stderr, fn -> assert {2, ""} = ehosctl(["whoami", "--", "--json"], dir) end)

    assert stderr =~ "ehosctl: "
  end

  test "says --installation in its help", %{tmp_dir: dir} do
    {0, help} = ehosctl(["whoami", "--help"], dir)
    assert help =~ "--installation"
    assert help =~ "Plane: governed."
  end

  test "does not run without an installation, and exits as not signed in", %{tmp_dir: dir} do
    stderr =
      capture_io(:stderr, fn ->
        assert {4, ""} = ehosctl(["whoami", "--installation", "nope"], dir)
      end)

    assert stderr == ~s(ehosctl: no installation is named "nope"\n)

    stderr =
      capture_io(:stderr, fn ->
        assert {4, ""} = ehosctl(["whoami", "--json"], Path.join(dir, "none"))
      end)

    assert %{"error" => %{"kind" => "not_signed_in"}} = JSON.decode!(stderr)
  end
end
