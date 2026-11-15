defmodule EhosApp.SkillGit do
  @moduledoc "The Git reader used to refresh pinned skill bundles, replaceable through the bundler's `:git` option."

  @doc "Reads Git's stdout in a checkout, or returns a command failure without Git's potentially sensitive output."
  @callback run([String.t()], Path.t()) :: {:ok, String.t()} | {:error, :command_failed}
end

defmodule EhosApp.SkillGitImpl do
  @moduledoc "Reads pinned Git objects through the installed Git executable."
  @behaviour EhosApp.SkillGit

  @impl true
  def run(args, checkout) do
    case System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _failure -> {:error, :command_failed}
    end
  rescue
    _error in ErlangError -> {:error, :command_failed}
  end
end
