defmodule Ehosctl.Browser do
  @moduledoc """
  The system's browser, for `ehosctl login`'s sign-in (RFC 8252 asks for the system's own) and
  `ehosctl changelog --web`.
  """

  @wait_ms 5_000

  @doc """
  Opens `url` in the system's browser with `open` on macOS and `xdg-open` elsewhere, and returns
  `:ok` whether or not one opened: the caller prints the URL besides.

  By default the opener runs apart, so a browser that runs in the terminal does not hold up the
  command: `login`'s listener must answer the browser meanwhile. With `wait: true` it is waited
  for, five seconds at most, or `wait:` milliseconds, as `changelog --web` needs: the binary halts
  as soon as the command returns, which would end an opener still starting. `open` hands the page
  to the browser and returns, and so does `xdg-open` on a desktop it knows; elsewhere it runs a
  browser in the foreground until that browser ends, which the bound does not wait for.
  `:command` names the opener instead, for the tests.
  """
  @spec open(String.t(), keyword()) :: :ok
  def open(url, opts \\ []) do
    executable =
      Keyword.get_lazy(opts, :command, fn ->
        System.find_executable(
          if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"
        )
      end)

    if executable do
      run = fn -> System.cmd(executable, [url], stderr_to_stdout: true) end
      start(run, Keyword.get(opts, :wait, false))
    end

    :ok
  end

  defp start(run, false), do: Task.start(run)

  defp start(run, wait),
    do: run |> Task.async() |> Task.yield(if(wait == true, do: @wait_ms, else: wait))
end
