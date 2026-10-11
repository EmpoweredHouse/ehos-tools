defmodule Ehosctl do
  @moduledoc """
  The terminal's way into EHOS.

  Its first command, `ehosctl init`, needs no EHOS at all: it creates an application
  from the template. The commands that talk to EHOS (`login`, `verify`, calling a
  declared command) follow as EHOS grows the API they go through.
  """

  # The commit this build is made from (`Ehosctl.Build`).
  @commit Ehosctl.Build.commit()

  @doc false
  # Asked by Mix before a compile: a checkout that moved to another commit recompiles this module,
  # so an incremental build does not keep the commit it was first compiled at. Never fails.
  def __mix_recompile__? do
    Ehosctl.Build.commit() != @commit
  rescue
    _error -> false
  end

  @doc "The version this binary was built as."
  @spec version() :: String.t()
  def version, do: Application.spec(:ehosctl, :vsn) |> to_string()

  @doc """
  The commit this binary was built from, 40 hexadecimal digits, or `nil` when the build was not
  told it and had no git checkout to ask.
  """
  @spec commit() :: String.t() | nil
  def commit, do: @commit
end
