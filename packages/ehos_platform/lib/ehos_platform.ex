defmodule EhosPlatform do
  @moduledoc """
  The code that makes the server under an EHOS installation and installs EHOS on it (eh-os D-92):
  `EhosPlatform.Server` (OpenTofu, k3s by cloud-init, the SSH tunnel), `EhosPlatform.Install`
  (the prerequisites, the installation's CA, the chart) and `EhosPlatform.Source` (what is
  installed: an eh-os checkout or a release).

  eh-os's tooling uses it to bring up a developer's cluster and to test installing on every pull
  request; `ehosctl`'s platform plane compiles it in (eh-os D-87). Every external program runs
  through `EhosPlatform.CommandRunner`, so the logic is tested without them.
  """

  @doc "This package's `release.json` (eh-os D-91): what it is, with nothing it produces or accepts."
  @spec release(String.t()) :: map()
  def release(commit) when is_binary(commit) do
    %{
      "schema" => "ehos.release/v1",
      "component" => "ehos_platform",
      "version" => to_string(Application.spec(:ehos_platform, :vsn)),
      "commit" => commit,
      "produces" => [],
      "accepts" => [],
      "requires" => %{}
    }
  end
end
