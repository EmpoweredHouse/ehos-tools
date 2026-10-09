defmodule Ehosctl.InstallationsTest do
  # Not async: capture_io(:stderr) captures stderr for every process, so tests that run
  # beside each other would read each other's errors.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    :ok =
      Config.write(
        %Config{
          current: "local",
          installations: %{
            "local" => %{"url" => "http://ehos.localhost"},
            "staging" => %{"url" => "https://ehos.staging.example.com"}
          }
        },
        dir
      )
  end

  defp ehosctl(argv, dir) do
    {code, stderr} =
      with_io(:stderr, fn ->
        stdout =
          capture_io(fn -> send(self(), {:code, Ehosctl.CLI.main(argv, config_dir: dir)}) end)

        send(self(), {:stdout, stdout})
      end)
      |> then(fn {_, stderr} -> {receive_code(), stderr} end)

    {code, receive_stdout(), stderr}
  end

  defp receive_code, do: receive(do: ({:code, code} -> code))
  defp receive_stdout, do: receive(do: ({:stdout, stdout} -> stdout))

  test "lists the installations, marking the current one", %{tmp_dir: dir} do
    {0, stdout, ""} = ehosctl(["installations", "list"], dir)

    assert stdout == """
            CURRENT  NAME     URL
            *        local    http://ehos.localhost
                     staging  https://ehos.staging.example.com
           """
  end

  test "lists them as JSON for a script", %{tmp_dir: dir} do
    {0, stdout, ""} = ehosctl(["installations", "list", "--json"], dir)

    assert JSON.decode!(stdout) == %{
             "current" => "local",
             "installations" => [
               %{"name" => "local", "url" => "http://ehos.localhost", "current" => true},
               %{
                 "name" => "staging",
                 "url" => "https://ehos.staging.example.com",
                 "current" => false
               }
             ]
           }
  end

  test "says so when there are none", %{tmp_dir: dir} do
    {0, stdout, ""} = ehosctl(["installations", "list"], Path.join(dir, "empty"))
    assert stdout == "No installations yet.\n"
  end

  test "makes one current, and the next list says so", %{tmp_dir: dir} do
    {0, "staging is the current installation.\n", ""} =
      ehosctl(["installations", "use", "staging"], dir)

    assert {:ok, %Config{current: "staging"}} = Config.read(dir)
  end

  test "forgets one", %{tmp_dir: dir} do
    {0, stdout, ""} = ehosctl(["installations", "remove", "local", "--json"], dir)
    assert JSON.decode!(stdout) == %{"removed" => "local", "current" => nil}
    assert {:ok, %Config{current: nil, installations: %{"staging" => _}}} = Config.read(dir)
  end

  test "refuses a name it does not know as invalid, and changes nothing", %{tmp_dir: dir} do
    before = File.read!(Config.path(dir))

    for sub <- ["use", "remove"] do
      {2, "", stderr} = ehosctl(["installations", sub, "nope"], dir)
      assert stderr == ~s(ehosctl: no installation is named "nope"\n)
    end

    assert File.read!(Config.path(dir)) == before
  end

  test "reports a configuration it cannot read as failed, with its own code", %{tmp_dir: dir} do
    File.write!(Config.path(dir), "{not json")
    {1, "", stderr} = ehosctl(["installations", "list"], dir)
    assert stderr =~ "is not JSON"
  end

  test "never prints a control character from the configuration to the terminal",
       %{tmp_dir: dir} do
    File.write!(
      Config.path(dir),
      ~s({"version":1,"installations":{"a":{"url":"x\\u001b]0;pwned\\u0007y"}}})
    )

    {1, "", stderr} = ehosctl(["installations", "list"], dir)
    assert stderr =~ "is not an ehosctl configuration"
    refute stderr =~ "\e"
  end

  test "prints its help when no subcommand is named", %{tmp_dir: dir} do
    {0, stdout, ""} = ehosctl(["installations"], dir)
    assert stdout =~ ~r/^    use +Make an installation the current one\.$/m
    assert stdout =~ "Plane: local."
  end
end
