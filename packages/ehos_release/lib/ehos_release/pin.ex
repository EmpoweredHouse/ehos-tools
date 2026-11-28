defmodule EhosRelease.Pin do
  @moduledoc """
  One pin a repository keeps into eh-os, ehos-tools or ehos_contract: which file holds it, under
  which name, and the repository, path and ref it names (eh-os D-205, "Between releases").

  `path` is where in the producer the pinned thing lives: a package's directory
  (`packages/ehos_platform`), a reusable workflow (`.github/workflows/ehos-release.yml`), the
  plugins' marketplace (`.claude-plugin/marketplace.json`), or `""` for the repository itself.
  `ref` is a full commit or a tag's name.
  """

  @enforce_keys [:file, :name, :repository, :path, :ref]
  defstruct @enforce_keys

  @typedoc "A pin, as `EhosRelease.Pins` reads it."
  @type t :: %__MODULE__{
          file: String.t(),
          name: String.t(),
          repository: String.t(),
          path: String.t(),
          ref: String.t()
        }

  @doc """
  Whether the ref is a full commit rather than a tag's name.

      iex> EhosRelease.Pin.commit?(%EhosRelease.Pin{file: "mix.lock", name: "a", repository: "o/r", path: "", ref: String.duplicate("a", 40)})
      true

      iex> EhosRelease.Pin.commit?(%EhosRelease.Pin{file: "mix.lock", name: "a", repository: "o/r", path: "", ref: "ehos-dev-v0.14.0"})
      false
  """
  @spec commit?(t()) :: boolean()
  def commit?(%__MODULE__{ref: ref}), do: ref =~ ~r/\A[0-9a-f]{40}\z/

  @doc """
  What a refusal calls the pin: its file and name, and what it names.

      iex> EhosRelease.Pin.describe(%EhosRelease.Pin{file: "mix.lock", name: "ehos_tunnel", repository: "EmpoweredHouse/ehos-tools", path: "packages/ehos_tunnel", ref: "0123abc"})
      "mix.lock: ehos_tunnel pins EmpoweredHouse/ehos-tools packages/ehos_tunnel at 0123abc"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = pin) do
    where = if pin.path == "", do: pin.repository, else: "#{pin.repository} #{pin.path}"
    "#{pin.file}: #{pin.name} pins #{where} at #{pin.ref}"
  end
end
