defmodule Ehosctl.Browser do
  @moduledoc """
  The system's browser, as a way out (T-20), for `ehosctl login`'s sign-in (RFC 8252 asks for the
  system's own) and `ehosctl changelog --web`. A test mocks it, and plays the browser itself.
  """

  @doc """
  Opens `url` in the system's browser, and returns `:ok` whether or not one opened: the caller
  prints the URL besides. `wait: true`, or `wait:` milliseconds, waits for the opener to return.
  """
  @callback open(url :: String.t(), opts :: [wait: boolean() | non_neg_integer()]) :: :ok

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.BrowserImpl do
  @moduledoc "The `Ehosctl.Browser` that opens the system's own."

  @behaviour Ehosctl.Browser

  @wait_ms 5_000

  # `open` on macOS and `xdg-open` elsewhere. By default the opener runs apart, so a browser that
  # runs in the terminal does not hold up the command: `login`'s listener must answer the browser
  # meanwhile. With `wait: true` it is waited for, five seconds at most, or `wait:` milliseconds,
  # as `changelog --web` needs: the binary halts as soon as the command returns, which would end an
  # opener still starting. `open` hands the page to the browser and returns, and so does `xdg-open`
  # on a desktop it knows; elsewhere it runs a browser in the foreground until that browser ends,
  # which the bound does not wait for.
  @impl true
  def open(url, opts) do
    opener = if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"

    if executable = Ehosctl.OS.current().find_executable(opener) do
      run = fn -> Ehosctl.Runner.current().run(executable, [url], []) end
      start(run, Keyword.get(opts, :wait, false))
    end

    :ok
  end

  defp start(run, false), do: Task.start(run)

  defp start(run, wait),
    do: run |> Task.async() |> Task.yield(if(wait == true, do: @wait_ms, else: wait))
end
