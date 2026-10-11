defmodule Ehosctl.Browser do
  @moduledoc """
  The system's browser, for `ehosctl login`'s sign-in (RFC 8252 asks for the system's own) and
  `ehosctl changelog --web`.
  """

  @doc """
  Opens `url` in the system's browser with `open` on macOS and `xdg-open` elsewhere, started
  apart, so a browser that runs in the terminal does not hold up the command. Returns `:ok`
  whether or not one opened: the caller prints the URL besides.
  """
  @spec open(String.t()) :: :ok
  def open(url) do
    command = if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"

    if executable = System.find_executable(command) do
      Task.start(fn -> System.cmd(executable, [url], stderr_to_stdout: true) end)
    end

    :ok
  end
end
