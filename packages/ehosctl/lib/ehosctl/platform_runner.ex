defmodule Ehosctl.PlatformRunner do
  @moduledoc """
  How the platform plane runs the programs `ehos_platform` asks for (T-13): an
  `EhosPlatform.CommandRunner`.

  A program `EhosPlatform.Tools` pins, `tofu`, `helm` or `kubectl`, runs at its pin through mise,
  as `mise exec <tool>@<version> -- <program> <args>`, so an operator runs the OpenTofu, Helm and
  kubectl EHOS is tested with whatever else is on their `PATH`. mise installs nothing on the way
  (`MISE_EXEC_AUTO_INSTALL=false`): a tool not installed fails at once, and `ehosctl doctor` names
  the command that installs it. Every other program, `ssh` first, is the system's.
  """

  @behaviour EhosPlatform.CommandRunner

  alias EhosPlatform.CommandRunner.System, as: Machine
  alias EhosPlatform.Tools

  @no_install {"MISE_EXEC_AUTO_INSTALL", "false"}

  @doc """
  The program, arguments and environment `program` with `args` runs as.

      iex> Ehosctl.PlatformRunner.command("helm", ["version"])
      {"mise", ["exec", "helm@4.3.0", "--", "helm", "version"], [{"MISE_EXEC_AUTO_INSTALL", "false"}]}

      iex> Ehosctl.PlatformRunner.command("ssh", ["-V"])
      {"ssh", ["-V"], []}
  """
  @spec command(String.t(), [String.t()]) ::
          {String.t(), [String.t()], [{String.t(), String.t()}]}
  def command(program, args) do
    case Tools.for_program(program) do
      %{tool: tool, version: version} ->
        {"mise", ["exec", "#{tool}@#{version}", "--", program | args], [@no_install]}

      nil ->
        {program, args, []}
    end
  end

  @impl true
  def run(program, args), do: run_env(program, args, [])

  @impl true
  def run_in(dir, program, args) do
    {cmd, args} = program |> command(args) |> through_env()
    Machine.run_in(dir, cmd, args)
  end

  @impl true
  def run_env(program, args, env) do
    {cmd, args, pinned} = command(program, args)
    Machine.run_env(cmd, args, pinned ++ env)
  end

  @impl true
  def run_bounded(program, args, timeout) do
    {cmd, args} = program |> command(args) |> through_env()
    Machine.run_bounded(cmd, args, timeout)
  end

  # Where the runner takes no environment, `env` sets it for the one program.
  defp through_env({cmd, args, []}), do: {cmd, args}

  defp through_env({cmd, args, env}),
    do: {"env", Enum.map(env, fn {name, value} -> "#{name}=#{value}" end) ++ [cmd | args]}
end
