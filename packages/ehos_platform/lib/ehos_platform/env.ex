defmodule EhosPlatform.Env do
  @moduledoc """
  The process environment, as a way out (T-20): where a passphrase, a token or a provider's
  account comes from when the caller does not give it, and where the operator's home directory is,
  so a test says what the environment holds without setting it. A caller names an implementation
  in `opts[:env]`, and `EhosPlatform.EnvImpl`, the process's own, is the default.
  """

  alias EhosPlatform.Shell

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil

  @doc "The home directory of the user this process runs as, as the system has it."
  @callback user_home() :: Path.t()

  @doc """
  The `EhosPlatform.Env` `opts[:env]` names, else, when it names none or is `nil`,
  `EhosPlatform.EnvImpl`.

  Raises `ArgumentError` when `:env` is not a module, with a message that holds none of it: the
  environment as a map, as `ehosctl` keeps it in its own `opts`, would otherwise reach an error
  message whole.
  """
  @spec from(keyword()) :: module()
  def from(opts) do
    case Keyword.get(opts, :env) do
      nil -> EhosPlatform.EnvImpl
      env when is_atom(env) and not is_boolean(env) -> env
      _other -> raise ArgumentError, ":env must name a module that implements EhosPlatform.Env"
    end
  end

  @doc """
  The operator's home directory, through the `EhosPlatform.Env` `opts[:env]` names: `HOME`, as a
  shell has it, when it is an absolute path of printable characters without `..`, else
  `c:user_home/0`'s, as an absolute path.
  """
  @spec home(keyword()) :: Path.t()
  def home(opts) do
    env = from(opts)
    home = env.get("HOME")

    if is_binary(home) and String.starts_with?(home, "/") and Shell.printable?(home) and
         ".." not in Path.split(home),
       do: Path.expand(home),
       else: Path.expand(env.user_home())
  end

  @doc """
  `path` as an absolute path, with `~` and `~/` under `home/1`'s home directory. Reads the home
  directory only for such a path.
  """
  @spec expand(Path.t(), keyword()) :: Path.t()
  def expand(path, opts) when not is_binary(path),
    do: path |> IO.chardata_to_string() |> expand(opts)

  def expand("~", opts), do: home(opts)
  def expand("~/" <> _rest = path, opts), do: expand_home(path, home(opts))
  def expand(path, _opts), do: Path.expand(path)

  @doc """
  `path` as an absolute path, with `~` and `~/` under `home`. A path that starts with `~` and
  any other character, such as `~ada/`, is taken as a name relative to the working directory, as
  `Path.expand/1` takes it.

      iex> EhosPlatform.Env.expand_home("~/.ehos", "/home/ada")
      "/home/ada/.ehos"

      iex> EhosPlatform.Env.expand_home("~//etc", "/home/ada")
      "/home/ada/etc"

      iex> EhosPlatform.Env.expand_home("/srv/ehos", "/home/ada")
      "/srv/ehos"
  """
  @spec expand_home(Path.t(), Path.t()) :: Path.t()
  def expand_home(path, home) when not is_binary(path),
    do: path |> IO.chardata_to_string() |> expand_home(home)

  def expand_home("~", home), do: Path.expand(home)
  def expand_home("~/" <> path, home), do: home |> Path.join(path) |> Path.expand()
  def expand_home(path, _home), do: Path.expand(path)
end

defmodule EhosPlatform.EnvImpl do
  @moduledoc """
  The `EhosPlatform.Env` of this process, read with `System.get_env/1` and `System.user_home!/0`.
  """

  @behaviour EhosPlatform.Env

  @impl true
  def get(name), do: System.get_env(name)

  @impl true
  def user_home, do: System.user_home!()
end
