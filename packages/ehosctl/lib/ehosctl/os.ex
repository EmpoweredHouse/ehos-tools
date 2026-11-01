defmodule Ehosctl.OS do
  @moduledoc """
  What ehosctl asks of the operating system, as a way out (T-20): which system it is, where a
  program is, the user's id and home directory, whether a process runs, and a directory's path
  with its links resolved. A test that must say what they are mocks it; `Ehosctl.Case` gives
  every other test this machine's answers.
  """

  @doc "The system ehosctl runs on, as `:os.type/0` names it, such as `{:unix, :darwin}`."
  @callback type() :: {:unix | :win32, atom()}

  @doc "The path of the executable `name` on the `PATH`, or `nil` when there is none."
  @callback find_executable(name :: String.t()) :: Path.t() | nil

  @doc "The user's id, as the files they create are owned by it, or `nil` when it cannot be read."
  @callback user_id() :: non_neg_integer() | nil

  @doc "The user's home directory, where the configuration and the sign-ins are kept by default."
  @callback home() :: Path.t()

  @doc """
  Whether the process `pid` of this machine runs, another user's included: only a process that
  is not there is not running.
  """
  @callback alive?(pid :: pos_integer()) :: boolean()

  @doc "`dir` with every link in it resolved, or `dir` itself when it cannot be."
  @callback physical(dir :: Path.t()) :: Path.t()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.OSImpl do
  @moduledoc """
  The `Ehosctl.OS` of this machine, asked of `System` and of `/usr/bin/id`, `/bin/kill` and
  `/bin/pwd`.
  """

  @behaviour Ehosctl.OS

  @impl true
  def type, do: :os.type()

  @impl true
  def find_executable(name), do: System.find_executable(name)

  # Asked of `/usr/bin/id` once, not through the PATH. `nil` when it cannot be, which no
  # directory's owner matches.
  @impl true
  def user_id do
    case :persistent_term.get({__MODULE__, :user_id}, :unknown) do
      :unknown ->
        id = read_user_id()
        :persistent_term.put({__MODULE__, :user_id}, id)
        id

      id ->
        id
    end
  end

  defp read_user_id do
    with {output, 0} <- System.cmd("/usr/bin/id", ["-u"]),
         {id, _rest} <- Integer.parse(output) do
      id
    else
      _failed -> nil
    end
  rescue
    ErlangError -> nil
  end

  @impl true
  def home, do: System.user_home!()

  @impl true
  def alive?(pid) do
    # `kill -0` fails on another user's process too ("Operation not permitted"), which runs, and
    # on one that is not there or an id none can have, which do not; its message is read in
    # English, as LC_ALL=C has it on every system.
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {_output, 0} -> true
      {output, _failed} -> String.contains?(output, "Operation not permitted")
    end
  end

  # sobelow_skip ["CI.System"]
  @impl true
  def physical(dir) do
    case System.cmd("/bin/pwd", ["-P"], cd: dir) do
      {path, 0} -> String.trim(path)
      _other -> dir
    end
  end
end
