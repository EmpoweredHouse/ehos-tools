defmodule EhosRelease.Version do
  @moduledoc """
  The version a release takes (eh-os D-205, "Versions"; T-34): the floor changie's `auto` gives
  from the fragments, raised by the maintainer's input `version` where a repository's own rule asks
  for more, and above the highest tag of the component's prefix.
  """

  @semver ~r/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

  @doc """
  Whether `version` is a plain `X.Y.Z`.

      iex> EhosRelease.Version.valid?("0.12.0")
      true

      iex> EhosRelease.Version.valid?("0.12.0-dev")
      false
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(version), do: is_binary(version) and version =~ @semver

  @doc """
  The highest `X.Y.Z` among the tags `<prefix>X.Y.Z`, or nil.

      iex> EhosRelease.Version.highest(["v0.9.0", "v0.10.0", "ehos_app-v1.0.0", "v0.11.0-rc"], "v")
      "0.10.0"
  """
  @spec highest([String.t()], String.t()) :: String.t() | nil
  def highest(tags, prefix) do
    tags
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.filter(&valid?/1)
    |> Enum.max(Version, fn -> nil end)
  end

  @doc """
  The version a release takes: the input when there is one, otherwise the highest of the floors.
  Refused when the input is not `X.Y.Z` or is below a floor, and when the version is not above the
  highest tag.

      iex> EhosRelease.Version.choose(["0.4.1", "0.5.0"], nil, "0.4.0")
      {:ok, "0.5.0"}

      iex> EhosRelease.Version.choose(["0.5.0"], "0.4.2", "0.4.0")
      {:error, "the version 0.4.2 is below 0.5.0, the floor its fragments give"}

      iex> EhosRelease.Version.choose(["0.4.0"], nil, "0.4.0")
      {:error, "the version 0.4.0 is not above 0.4.0, the highest tag of the component"}
  """
  @spec choose([String.t()], String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def choose([_ | _] = floors, input, highest) do
    floor = Enum.max(floors, Version)
    version = input || floor

    cond do
      not valid?(version) ->
        {:error, "the version #{inspect(version)} is not X.Y.Z"}

      Version.compare(version, floor) == :lt ->
        {:error, "the version #{version} is below #{floor}, the floor its fragments give"}

      highest != nil and Version.compare(version, highest) != :gt ->
        {:error,
         "the version #{version} is not above #{highest}, the highest tag of the component"}

      true ->
        {:ok, version}
    end
  end
end
