defmodule EhosRelease do
  @moduledoc """
  The logic of eh-os D-205's release workflow, `.github/workflows/ehos-release.yml`, and of its
  check of pins, `.github/workflows/ehos-pins.yml`, which eh-os, ehos-tools and ehos_contract call
  (T-34). Each Mix task of the package is a function here, which takes its ways out in `opts`
  (`:git`, `:github`), so a test runs it against mocks.

  A caller's repository is read as data, never compiled or evaluated: a job that runs this holds
  a token that reads GitHub on the caller's behalf.
  """

  alias EhosRelease.{Config, PinCheck, Pins, Source}

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

    with :ok <- revision(base),
         {:ok, config} <- config(head) do
      sources = Config.pin_sources(config)
      {head_pins, head_refusals} = Pins.read(head, sources)
      changed = changed(Source.at(dir, base, git), sources, head_pins)

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

  defp read_config(source) do
    case Source.read(source, Config.path()) do
      {:ok, json} -> {:ok, json}
      :missing -> {:error, "#{Config.path()} is missing"}
      {:error, _reason} = error -> error
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
