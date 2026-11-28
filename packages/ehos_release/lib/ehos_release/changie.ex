defmodule EhosRelease.Changie do
  @moduledoc """
  changie, as a way out (T-20): the floor of a project's next version, and the release of its
  fragments into its changelog. A caller names an implementation in `opts[:changie]`, and
  `EhosRelease.ChangieImpl` is the default.
  """

  @doc """
  The next version of `project` that its fragments give, changie's `auto` (T-34), or `:none` when
  the project has no fragment.
  """
  @callback next(dir :: Path.t(), project :: String.t()) ::
              {:ok, String.t()} | :none | {:error, String.t()}

  @doc "Batches the fragments of `project` into its version file for `version`, and deletes them."
  @callback batch(dir :: Path.t(), project :: String.t(), version :: String.t()) ::
              :ok | {:error, String.t()}

  @doc "Writes every project's changelog from its version files."
  @callback merge(dir :: Path.t()) :: :ok | {:error, String.t()}
end

defmodule EhosRelease.ChangieImpl do
  @moduledoc """
  The `EhosRelease.Changie` that runs changie in the caller's checkout: the one
  `EHOS_RELEASE_CHANGIE` names, where `ehos-release.yml` puts the changie
  `packages/ehos_release/.tool-versions` pins, otherwise the one on the `PATH`. It runs with no
  token in its environment: its templates, which the caller writes, can read the environment.
  """

  @behaviour EhosRelease.Changie

  @impl true
  def next(dir, project) do
    case changie(dir, ["next", "auto", "--project", project]) do
      {:ok, output} -> version(output)
      {:error, output, _status} -> none_or_error(output, "changie next of #{project}")
    end
  end

  @impl true
  def batch(dir, project, version) do
    case changie(dir, ["batch", version, "--project", project]) do
      {:ok, _output} -> :ok
      {:error, _output, status} -> {:error, "changie batch of #{project} exited with #{status}"}
    end
  end

  @impl true
  def merge(dir) do
    case changie(dir, ["merge"]) do
      {:ok, _output} -> :ok
      {:error, _output, status} -> {:error, "changie merge exited with #{status}"}
    end
  end

  # changie prints the project's key and its separator before the version, `shop@0.2.0`.
  defp version(output) do
    case Regex.run(~r/(\d+\.\d+\.\d+)\s*\z/, output, capture: :all_but_first) do
      [version] -> {:ok, version}
      nil -> {:error, "changie next printed no version"}
    end
  end

  # No fragment, or no directory of fragments, as a repository with none has after `git clone`.
  defp none_or_error(output, what) do
    if output =~ "no unreleased changes" or output =~ ~r/open \S*unreleased: no such file/,
      do: :none,
      else: {:error, "#{what} failed"}
  end

  defp changie(dir, args) do
    case changie_path() do
      nil -> {:error, "", "not found, as changie is not on the PATH"}
      changie -> run(changie, args, dir)
    end
  end

  # The workflow names the changie it installed: a mise shim on the PATH would read the version
  # from the caller's checkout, where changie runs, not from this package's `.tool-versions`.
  defp changie_path do
    case System.get_env("EHOS_RELEASE_CHANGIE") do
      path when path in [nil, ""] -> System.find_executable("changie")
      path -> System.find_executable(path)
    end
  end

  defp run(changie, args, dir) do
    case System.cmd(changie, args,
           cd: dir,
           stderr_to_stdout: true,
           env: EhosRelease.GitImpl.child_env()
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, output, status}
    end
  end
end
