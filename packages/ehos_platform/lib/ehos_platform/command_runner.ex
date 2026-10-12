defmodule EhosPlatform.CommandRunner do
  @moduledoc """
  Runs an external program for EHOS's developer tooling.

  Mix tasks such as `mix ehos.doctor` drive `docker`, `kubectl`, `k3d` and `helm`. They do so only
  through this behaviour, so their logic can be tested without those programs installed (D-27).
  """

  @typedoc "What a finished program returned: its combined output and its exit status."
  @type result :: {output :: String.t(), exit_status :: non_neg_integer()}

  @doc """
  Runs `program` with `args` and returns its output and exit status.

  Returns `{:error, :not_found}` when `program` is not on the `PATH`, so a missing tool is an
  ordinary result rather than an exception.
  """
  @callback run(program :: String.t(), args :: [String.t()]) :: result() | {:error, :not_found}

  @doc """
  Runs `program` with `args` in the directory `dir`, otherwise as `c:run/2`.
  """
  @callback run_in(dir :: Path.t(), program :: String.t(), args :: [String.t()]) ::
              result() | {:error, :not_found}

  @doc """
  Runs `program` with `args` and these variables added to its environment, otherwise as `c:run/2`.

  For values a program must not get on its command line, where any user of the machine can read
  them: a passphrase, for one. A variable given `nil` is taken out of the program's environment.
  """
  @callback run_env(
              program :: String.t(),
              args :: [String.t()],
              env :: [{String.t(), String.t() | nil}]
            ) :: result() | {:error, :not_found}

  @doc """
  Runs `program` with `args`, as `c:run/2`, for at most `timeout` milliseconds: a program still
  running then is killed, and the result is `{:error, :timeout}`. For a command that can wait for
  ever on something it does not control, an SSH control socket whose master is wedged, for one.
  """
  @callback run_bounded(program :: String.t(), args :: [String.t()], timeout :: pos_integer()) ::
              result() | {:error, :not_found} | {:error, :timeout}
end
