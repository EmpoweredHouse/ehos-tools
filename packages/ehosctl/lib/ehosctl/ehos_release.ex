defmodule Ehosctl.EhosRelease do
  @moduledoc """
  An EHOS release and its `release.json` (eh-os D-91, D-92), as the platform commands take them:
  the one a version names, or the newest. `ehosctl server` makes a server from its OpenTofu
  modules (`Ehosctl.ServerRelease`), and `ehosctl install` installs its image and chart.
  """

  alias Ehosctl.GitHub
  alias Ehosctl.Refusal

  @doc """
  The release of EHOS `version` names, or the newest when `version` is `nil`, with its
  `release.json` decoded and checked to be that release's (`Ehosctl.GitHub.release_json/2`):
  `nil` for a release that carries none. `opts` are `Ehosctl.GitHub`'s.
  """
  @spec find(String.t() | nil, keyword()) ::
          {:ok, GitHub.release(), map() | nil} | {:error, Ehosctl.Output.kind(), String.t()}
  def find(version, opts) do
    with {:ok, releases} <- GitHub.releases("ehos", opts),
         {:ok, release} <- chosen(releases, version),
         {:ok, described} <- GitHub.release_json(release, opts) do
      {:ok, release, described}
    end
  end

  defp chosen([], _version), do: {:error, :failed, "EHOS has no release yet."}
  defp chosen([newest | _], nil), do: {:ok, newest}

  defp chosen(releases, version) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> {:error, :invalid, "EHOS has no release #{Refusal.shown(version)}."}
      release -> {:ok, release}
    end
  end
end
