defmodule Ehosctl.Version do
  @moduledoc """
  What this `ehosctl` says about itself in a release (eh-os D-91): the `release.json` published
  beside its binaries, schema `ehos.release/v1`, which
  [docs/releases.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)
  describes.

  It is built from the code, not written by hand: the version is the one this build carries
  (`Ehosctl.version/0`), and the `ehos_app` it creates applications from is the one
  `Ehosctl.Template` pins. `mix ehosctl.release_file` writes it, and CI's release job publishes
  it.
  """

  alias Ehosctl.Template

  @schema "ehos.release/v1"

  # The interfaces this ehosctl reads (eh-os D-91): EHOS's API, `ehos.api/v1`, which it calls at
  # `/api/v1`, and an application's routes, which `ehosctl call` calls through eh_os_contract.
  @accepts ["ehos.api/v1", "eh_os_contract.api/v1"]

  @doc """
  The interfaces this `ehosctl` reads, `<name>/v<N>`.

      iex> Ehosctl.Version.accepts()
      ["ehos.api/v1", "eh_os_contract.api/v1"]
  """
  @spec accepts() :: [String.t()]
  def accepts, do: @accepts

  @doc """
  The release's description, as a map ready to encode as JSON. `commit` is the commit the
  release is built from, which only the caller knows.

  `produces` and `accepts` list the interfaces, `<name>/v<N>`, that this `ehosctl` produces and
  reads: it produces none, and reads EHOS's API, `ehos.api/v1`, and an application's routes,
  `eh_os_contract.api/v1`. `pins` names the version of each component it creates from.

      iex> release = Ehosctl.Version.release(commit: "0123456789abcdef0123456789abcdef01234567")
      iex> {release["schema"], release["component"], release["produces"]}
      {"ehos.release/v1", "ehosctl", []}
  """
  @spec release(commit: String.t()) :: %{String.t() => term()}
  def release(opts) do
    %{
      "schema" => @schema,
      "component" => "ehosctl",
      "version" => Ehosctl.version(),
      "commit" => Keyword.fetch!(opts, :commit),
      "produces" => [],
      "accepts" => @accepts,
      "requires" => %{},
      "pins" => %{"ehos_app" => Template.template_version()}
    }
  end
end
