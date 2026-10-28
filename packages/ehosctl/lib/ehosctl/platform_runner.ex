defmodule Ehosctl.PlatformRunner do
  @moduledoc """
  How the platform plane runs the programs `ehos_platform` asks for (T-13): an
  `EhosPlatform.CommandRunner`.

  A program `EhosPlatform.Tools` pins, `tofu`, `helm` or `kubectl`, runs as the binary mise
  installed for its pin, found with `mise which <program> --tool <tool>@<version>` and then run
  directly. mise is asked from a private, empty directory, `MISE_CEILING_PATHS` stops it there, and
  `MISE_PARANOID` refuses any configuration it was not told to trust, so a `mise.toml` or
  `.tool-versions` where the operator stands, or above it, chooses no binary, sets no variable and
  runs no hook of its own. The tool's process gets no environment from mise at all. A pin not
  installed is a program not found, which `ehosctl doctor` says how to install; nothing is
  downloaded on the way, and no other version runs in its place.

  Every other program, `ssh` first, is the system's, from the `PATH`.
  """

  @behaviour EhosPlatform.CommandRunner

  alias EhosPlatform.CommandRunnerImpl, as: Machine
  alias EhosPlatform.TmpDir
  alias EhosPlatform.Tools

  @doc """
  The executable `program` runs as: the binary of its pin for a pinned one, found through mise,
  else the program's own name. `opts[:mise]` is mise's path, for tests; else the one on the `PATH`.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve(program, opts \\ []) do
    case Tools.for_program(program) do
      nil ->
        {:ok, program}

      tool ->
        pinned(tool, Keyword.get_lazy(opts, :mise, fn -> System.find_executable("mise") end))
    end
  end

  defp pinned(_tool, nil), do: {:error, :not_found}

  # sobelow_skip ["CI.System"]
  defp pinned(%{tool: tool, program: program, version: version}, mise) do
    TmpDir.with_tmp_dir("ehosctl-mise", fn tmp ->
      # The directory as the process sees it, links resolved (macOS's /var is /private/var), so
      # the ceiling mise compares against is the directory it stands in.
      dir = physical(tmp)

      env = [
        {"MISE_CEILING_PATHS", dir},
        {"MISE_PARANOID", "1"},
        {"MISE_QUIET", "1"},
        {"MISE_EXEC_AUTO_INSTALL", "false"}
      ]

      case System.cmd(mise, ["which", program, "--tool", "#{tool}@#{version}"],
             cd: dir,
             env: env,
             stderr_to_stdout: true
           ) do
        {output, 0} -> executable(output)
        _not_installed -> {:error, :not_found}
      end
    end)
  end

  # sobelow_skip ["CI.System"]
  defp physical(dir) do
    case System.cmd("/bin/pwd", ["-P"], cd: dir) do
      {path, 0} -> String.trim(path)
      _other -> dir
    end
  end

  # The path mise printed, once it is an executable file.
  defp executable(output) do
    path = output |> String.split("\n", trim: true) |> List.last("") |> String.trim()

    if Path.type(path) == :absolute and match?({:ok, %File.Stat{type: :regular}}, File.stat(path)),
      do: {:ok, path},
      else: {:error, :not_found}
  end

  @impl true
  def run(program, args), do: with_resolved(program, &Machine.run(&1, args))

  @impl true
  def run_in(dir, program, args), do: with_resolved(program, &Machine.run_in(dir, &1, args))

  @impl true
  def run_env(program, args, env), do: with_resolved(program, &Machine.run_env(&1, args, env))

  @impl true
  def run_bounded(program, args, timeout),
    do: with_resolved(program, &Machine.run_bounded(&1, args, timeout))

  defp with_resolved(program, run) do
    case resolve(program) do
      {:ok, executable} -> run.(executable)
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
