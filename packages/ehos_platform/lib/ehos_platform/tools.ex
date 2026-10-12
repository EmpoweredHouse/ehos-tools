defmodule EhosPlatform.Tools do
  @moduledoc """
  The programs this package runs whose version matters, and the versions EHOS is tested with
  (eh-os D-92, ehos-tools T-13): the ones eh-os's `.tool-versions` pins, which its Cluster job
  installs with. A caller that can choose its tools, as `ehosctl` does through mise, runs these.

  OpenTofu writes a server's state in its own version's format and refuses a newer one, so every
  machine that runs `ehosctl server` for an installation runs the same OpenTofu.

  `ssh`, `sh` and `gh` are the system's, at whatever version it has.
  """

  @tools [
    %{tool: "opentofu", program: "tofu", version: "1.13.1"},
    %{tool: "helm", program: "helm", version: "4.3.0"},
    %{tool: "kubectl", program: "kubectl", version: "1.36.4"}
  ]

  @typedoc "A pinned tool: its name to mise, the program it gives, and its version."
  @type t :: %{tool: String.t(), program: String.t(), version: String.t()}

  @doc """
  Every pinned tool.

      iex> Enum.map(EhosPlatform.Tools.all(), & &1.program)
      ["tofu", "helm", "kubectl"]
  """
  @spec all() :: [t()]
  def all, do: @tools

  @doc """
  The pinned tool that gives `program`, or `nil` for one that is the system's.

      iex> EhosPlatform.Tools.for_program("tofu")
      %{tool: "opentofu", program: "tofu", version: "1.13.1"}

      iex> EhosPlatform.Tools.for_program("ssh")
      nil
  """
  @spec for_program(String.t()) :: t() | nil
  def for_program(program), do: Enum.find(@tools, &(&1.program == program))
end
