defmodule EhosApp do
  @moduledoc """
  What an application needs to run on EHOS, as a dependency it keeps.

  Today that is the installer, `mix ehos_app.install`, which `ehosctl init` runs on a
  fresh Phoenix project. What it writes follows what EHOS decided: `ehos.yaml`, the
  health endpoints, the variables an application is given at start, and the credential
  check in front of the contracts. An application gets a later version by moving its
  dependency to it and running `mix ehos_app.install` again (ehos-tools T-02).
  """

  @doc """
  The version of `ehos.yaml` the installer writes into a new project, as its `schema:` says:
  the interface this `ehos_app` produces, which EHOS has to accept (eh-os D-91).

      iex> EhosApp.ehos_yaml_version()
      "ehos.yaml/v2"
  """
  @spec ehos_yaml_version() :: String.t()
  def ehos_yaml_version, do: "ehos.yaml/v2"

  @doc """
  What a release of this `ehos_app` says about itself in its `release.json`, schema
  `ehos.release/v1` ([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)):
  its version, the `commit` it is made from, which only the caller knows, and the `ehos.yaml`
  it produces. `mix ehos_app.release_file`, an alias of this package's own, writes it.

      iex> release = EhosApp.release("0123456789abcdef0123456789abcdef01234567")
      iex> {release["component"], release["produces"]}
      {"ehos_app", ["ehos.yaml/v2"]}
  """
  @spec release(String.t()) :: %{String.t() => term()}
  def release(commit) when is_binary(commit) do
    %{
      "schema" => "ehos.release/v1",
      "component" => "ehos_app",
      "version" => to_string(Application.spec(:ehos_app, :vsn)),
      "commit" => commit,
      "produces" => [ehos_yaml_version()],
      "accepts" => [],
      "requires" => %{}
    }
  end
end
