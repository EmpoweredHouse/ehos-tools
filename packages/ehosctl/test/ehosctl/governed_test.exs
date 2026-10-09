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

  setup %{tmp_dir: dir} do
    :ok =
      Config.write(
        %Config{
          current: "local",
          installations: %{"local" => %{"url" => "u1"}, "staging" => %{"url" => "u2"}}
        },
        dir
      )
  end

  defp ehosctl(argv, dir) do
    capture_io(fn ->
      send(self(), {:code, Ehosctl.CLI.main(argv, commands: [Whoami], config_dir: dir)})
    end)
    |> then(fn stdout -> {receive(do: ({:code, code} -> code)), stdout} end)
  end

  test "talks to the current installation", %{tmp_dir: dir} do
    assert ehosctl(["whoami"], dir) == {0, "local at u1\n"}
  end

  test "talks to the one --installation names", %{tmp_dir: dir} do
    assert ehosctl(["whoami", "--installation", "staging"], dir) == {0, "staging at u2\n"}
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
