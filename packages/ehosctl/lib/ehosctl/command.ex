defmodule Ehosctl.Command do
  @moduledoc """
  What every `ehosctl` command declares: its place in the command line, its plane, and the
  function that runs it.

  The plane is the one eh-os D-87 gives every command, and `Ehosctl.CLI` prints it in the
  command's help:

    * `:governed` acts as a person EHOS knows, through EHOS's API, with only what
      `ehosctl login` obtained; EHOS decides and records every call.
    * `:platform` acts with an account EHOS does not issue: a cloud provider's, an SSH key,
      a kubeconfig. It never reads or writes an application's data.
    * `:local` needs neither: it works on this machine alone, as `init` does.
  """

  @type plane :: :governed | :platform | :local

  @typedoc """
  What a command returns: an exit code it has already reported on, or a result for
  `Ehosctl.Output` to print, or an error of a kind with a stable exit code, and, for a refusal of
  EHOS's, what `--json` prints beside it (`Ehosctl.Output.error/4`).
  """
  @type result ::
          non_neg_integer()
          | {:ok, Ehosctl.Output.t()}
          | {:error, Ehosctl.Output.kind(), String.t()}
          | {:error, Ehosctl.Output.kind(), String.t(), Ehosctl.Output.refusal()}

  @doc "The command's name on the command line, as an atom: `:init` for `ehosctl init`."
  @callback name() :: atom()

  @doc """
  The command's declaration for Optimus (T-06): `about`, `args`, `flags`, `options` and
  `subcommands`, without the name.
  """
  @callback spec() :: keyword()

  @doc "The plane the command belongs to (eh-os D-87)."
  @callback plane() :: plane()

  @doc """
  Runs the command. `path` names the subcommand under this command (`[]` for the command
  itself), `parsed` is what Optimus read, and `opts` are what tests inject.
  """
  @callback call(path :: [atom()], parsed :: Optimus.ParseResult.t(), opts :: keyword()) ::
              result()

  @doc """
  Whether the command chooses its installation itself, as `ehosctl login` does from its URL. A
  governed command that does not is handed the one `--installation`, `EHOSCTL_INSTALLATION` or
  the current one names, and does not run without one (T-07). Optional; `false` when not defined.
  """
  @callback chooses_installation?() :: boolean()

  @doc """
  Whether the command runs with no subcommand although it has some, as `ehosctl apps` lists the
  applications and `ehosctl apps register` registers one. A command with subcommands that does not
  prints its help instead. Optional; `false` when not defined.
  """
  @callback runs_bare?() :: boolean()

  @optional_callbacks chooses_installation?: 0, runs_bare?: 0

  @doc "The planes a command can belong to."
  @spec planes() :: [plane()]
  def planes, do: [:governed, :platform, :local]
end
