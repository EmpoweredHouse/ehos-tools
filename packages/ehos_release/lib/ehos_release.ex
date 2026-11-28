defmodule EhosRelease do
  @moduledoc """
  The logic of eh-os D-205's release workflow, `.github/workflows/ehos-release.yml`, and of its
  check of pins, `.github/workflows/ehos-pins.yml`, which eh-os, ehos-tools and ehos_contract call
  (T-34). Each Mix task of the package is a function here, which takes its ways out in `opts`
  (`:git`, `:github`), so a test runs it against mocks.

  A caller's repository is read as data, never compiled or evaluated: a job that runs this holds
  a token that reads GitHub on the caller's behalf.
  """

  alias EhosRelease.{ChangieConfig, Config, PinCheck, Pins, Source}

  @doc "The stage `open`: `EhosRelease.Open.open/5`."
  @spec open(Path.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, EhosRelease.Open.release()} | {:error, [String.t()]}
  defdelegate open(dir, repository, component, version, opts \\ []), to: EhosRelease.Open

  @doc "The stage `merged`: `EhosRelease.Merged.merged/4`."
  @spec merged(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, EhosRelease.Merged.release()} | {:error, [String.t()]}
  defdelegate merged(dir, repository, commit, opts \\ []), to: EhosRelease.Merged

  @doc """
  The check of every pull request (`mix ehos_release.pins`): each pin the checkout in `dir` adds
  or moves against the commit `base` names a commit its producer's `main` contains.

  Answers the pins it checked, or a refusal for each that failed and each file that could not be
  read. When the base cannot be read, every pin at the head is checked.
  """
  @spec pins(Path.t(), String.t(), keyword()) ::
          {:ok, [EhosRelease.Pin.t()]} | {:error, [String.t()]}
  def pins(dir, base, opts \\ []) do
    git = Keyword.get(opts, :git, EhosRelease.GitImpl)
    head = Source.checkout(dir)

    base_source = Source.at(dir, base, git)

    with :ok <- revision(base),
         {:ok, config} <- config(head) do
      sources = Config.pin_sources(config)
      # The base's sources too: a pull request that drops a file from its configuration does
      # not drop that file's pins from this check.
      base_only = base_sources(base_source) -- sources
      {head_pins, head_refusals} = Pins.read(head, sources)
      {kept_pins, kept_refusals} = Pins.read(head, base_only, missing: :empty)
      all = sources ++ base_only
      changed = changed(base_source, all, head_pins ++ kept_pins)
      head_refusals = head_refusals ++ kept_refusals

      case head_refusals ++ PinCheck.on_main(changed, opts) do
        [] -> {:ok, changed}
        refusals -> {:error, refusals}
      end
    end
  end

  @doc "The repository's `EhosRelease.Config`, read from `source`."
  @spec config(Source.t()) :: {:ok, Config.t()} | {:error, [String.t()]}
  def config(%Source{} = source) do
    with {:ok, json} <- read_config(source),
         {:ok, config} <- Config.parse(json) do
      {:ok, config}
    else
      {:error, reason} -> {:error, [reason]}
    end
  end

  @doc "The repository's `EhosRelease.ChangieConfig`, read from `source`."
  @spec changie_config(Source.t()) :: {:ok, ChangieConfig.t()} | {:error, [String.t()]}
  def changie_config(%Source{} = source) do
    with {:ok, yaml} <- read(source, ChangieConfig.path()),
         {:ok, config} <- ChangieConfig.parse(yaml) do
      {:ok, config}
    else
      {:error, reason} -> {:error, [reason]}
    end
  end

  @doc """
  Whether `component`'s changie projects are projects of the changie configuration, and its
  changelogs are theirs: the job that holds the key reads the changelogs from
  `.github/ehos-release.json` with `jq`, since it reads no YAML (T-34). The fragments are under
  `.changes/`, the one directory that job lets a release change.
  """
  @spec consistent(Config.Component.t(), ChangieConfig.t()) :: :ok | {:error, [String.t()]}
  def consistent(component, %ChangieConfig{projects: projects} = changie_config) do
    unknown = Enum.reject(component.changie_projects, &Map.has_key?(projects, &1))
    changelogs = component.changie_projects |> Enum.map(&projects[&1]) |> Enum.reject(&is_nil/1)

    cond do
      changie_config.changes_dir != ".changes" ->
        {:error,
         [
           ".changie.yaml's changesDir is #{inspect(changie_config.changes_dir)}, not .changes, " <>
             "the one directory of fragments a release may change"
         ]}

      unknown != [] ->
        {:error,
         [
           "#{component.name} names changie projects .changie.yaml does not have: " <>
             Enum.join(unknown, ", ")
         ]}

      Enum.sort(changelogs) != Enum.sort(component.changelogs) ->
        {:error,
         [
           "#{component.name}'s changelogs are not those of its changie projects: " <>
             Enum.join(Enum.sort(changelogs), ", ")
         ]}

      true ->
        :ok
    end
  end

  defp read(source, path) do
    case Source.read(source, path) do
      {:ok, text} -> {:ok, text}
      :missing -> {:error, "#{path} is missing"}
      {:error, _reason} = error -> error
    end
  end

  defp read_config(source) do
    case Source.read(source, Config.path()) do
      {:ok, json} -> {:ok, json}
      :missing -> {:error, "#{Config.path()} is missing"}
      {:error, _reason} = error -> error
    end
  end

  defp base_sources(base) do
    case config(base) do
      {:ok, config} -> Config.pin_sources(config)
      {:error, _reasons} -> []
    end
  end

  defp changed(base, sources, head_pins) do
    case Pins.read(base, sources, missing: :empty) do
      {base_pins, []} -> Pins.changed(base_pins, head_pins)
      {_base_pins, _refusals} -> head_pins
    end
  end

  defp revision(rev) do
    if rev =~ ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z},
      do: :ok,
      else: {:error, ["#{inspect(rev)} is not a commit or a branch"]}
  end
end
