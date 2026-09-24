defmodule Ehosctl do
  @moduledoc """
  The terminal's way into EHOS.

  Its first command, `ehosctl init`, needs no EHOS at all: it creates an application
  from the template. The commands that talk to EHOS (`login`, `verify`, calling a
  declared command) follow as EHOS grows the API they go through.
  """

  @doc "The version this binary was built as."
  @spec version() :: String.t()
  def version, do: Application.spec(:ehosctl, :vsn) |> to_string()
end
