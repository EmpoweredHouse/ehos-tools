defmodule Ehosctl.EhosRelease do
  @moduledoc """
  An EHOS release and its `release.json` (eh-os D-91, D-92), as the platform commands take them:
  the one a version names, or the newest. `ehosctl server` makes a server from its OpenTofu
  modules (`Ehosctl.ServerRelease`), and `ehosctl install` installs its image and chart.
  """

  alias Ehosctl.GitHub
  alias Ehosctl.Refusal

  @image ~r/\Aghcr\.io\/empoweredhouse\/ehos@(sha256:[0-9a-f]{64})\z/
  @chart ~r/\Aoci:\/\/ghcr\.io\/empoweredhouse\/charts\/ehos@sha256:[0-9a-f]{64}\z/

  @doc """
  The release of EHOS `version` names, or the newest when `version` is `nil`, with its
  `release.json` decoded and checked to be that release's (`Ehosctl.GitHub.release_json/2`):
  `nil` for a release that carries none. `opts` are `Ehosctl.GitHub`'s.
  """
  @spec find(String.t() | nil, keyword()) ::
          {:ok, GitHub.release(), map() | nil}
          | {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message()}
  def find(version, opts) do
    with {:ok, releases} <- GitHub.releases("ehos", opts),
         {:ok, release} <- chosen(releases, version),
         {:ok, described} <- GitHub.release_json(release, opts) do
      {:ok, release, described}
    end
  end

  @doc """
  The release of `releases`, newest first as `Ehosctl.GitHub.releases/2` lists them, that
  `version` names, or the newest when `version` is `nil`.
  """
  @spec chosen([GitHub.release()], String.t() | nil) ::
          {:ok, GitHub.release()} | {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message()}
  def chosen([], _version), do: {:error, :failed, "EHOS has no release yet."}
  def chosen([newest | _], nil), do: {:ok, newest}

  def chosen(releases, version) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> {:error, :invalid, "EHOS has no release #{Refusal.shown(version)}."}
      release -> {:ok, release}
    end
  end

  @doc """
  What a release installs, from its `release.json`: its `"version"`, its `"image"` and `"chart"`,
  each EmpoweredHouse's by digest, and the image's `"digest"`. An error for a release that names
  none, as those before eh-os D-92 do.
  """
  @spec installable(GitHub.release(), map() | nil) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message()}
  def installable(release, described) do
    with %{"version" => version, "image" => image, "chart" => chart}
         when is_binary(version) and is_binary(image) and is_binary(chart) <- described || %{},
         [_image, digest] <- Regex.run(@image, image),
         true <- chart =~ @chart do
      {:ok, %{"version" => version, "image" => image, "chart" => chart, "digest" => digest}}
    else
      _unnamed ->
        {:error, :failed,
         "#{release.tag} does not name an image and a chart of EHOS by digest, so ehosctl " <>
           "cannot install it. Give a later release."}
    end
  end

  @doc """
  The image's digest a `release.json` names, `sha256:…`, or `nil` when it names none of
  EmpoweredHouse's by digest.
  """
  @spec image_digest(map() | nil) :: String.t() | nil
  def image_digest(%{"image" => image}) when is_binary(image) do
    case Regex.run(@image, image) do
      [_image, digest] -> digest
      nil -> nil
    end
  end

  def image_digest(_described), do: nil
end
