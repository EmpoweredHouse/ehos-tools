defmodule Ehosctl.SignInCase do
  @moduledoc """
  What the tests of `login`, `logout`, `whoami` and the credentials share: a fake EHOS
  (`Ehosctl.FakeProvider`), a configuration and a state directory of their own, a fake keychain,
  and `ehosctl/2`, which runs a command line and returns its exit code, stdout and stderr.

  Not async: `capture_io(:stderr)` captures stderr for every process.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Ehosctl.Case, async: false

      import Ehosctl.SignInCase

      alias Ehosctl.Config
      alias Ehosctl.FakeKeychain
      alias Ehosctl.FakeProvider
      alias Ehosctl.TokenStore

      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: tmp_dir} do
    provider = Ehosctl.FakeProvider.start()

    opts = [
      config_dir: Path.join(tmp_dir, "config"),
      state_dir: Path.join(tmp_dir, "state"),
      keychain: Ehosctl.FakeKeychain,
      # The fake EHOS is plain HTTP, on a local port.
      allow_http: true,
      open_browser: Ehosctl.FakeProvider.browser(provider),
      warn: fn message -> send(self(), {:warn, message}) end,
      timeout: 5_000
    ]

    %{provider: provider, opts: opts}
  end

  @doc "Runs `argv` with `opts`, returning `{exit code, stdout, stderr}`."
  @spec ehosctl([String.t()], keyword()) :: {non_neg_integer(), String.t(), String.t()}
  def ehosctl(argv, opts) do
    test = self()

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        stdout =
          ExUnit.CaptureIO.capture_io(fn ->
            send(test, {:code, Ehosctl.CLI.main(argv, opts)})
          end)

        send(test, {:stdout, stdout})
      end)

    receive do
      {:code, code} ->
        receive do
          {:stdout, stdout} -> {code, stdout, stderr}
        end
    end
  end

  @doc "Signs in to the fake provider as `name`, and returns the command's stdout."
  @spec login!(Ehosctl.FakeProvider.t(), keyword(), [String.t()]) :: String.t()
  def login!(provider, opts, extra \\ []) do
    {0, stdout, _stderr} = ehosctl(["login", provider.issuer | extra], opts)
    stdout
  end
end
