defmodule Ehosctl.Installations do
  @moduledoc """
  `ehosctl installations list | use NAME | remove NAME`: the installations a person knows,
  and which one is current (T-07).

  These read and write `Ehosctl.Config` and nothing else, so they are on the local plane: they
  never reach a sign-in (T-08), and `remove` leaves one where it is. Adding an installation is
  `ehosctl login`'s.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.Output

  @impl Ehosctl.Command
  def name, do: :installations

  @impl Ehosctl.Command
  def plane, do: :local

  @impl Ehosctl.Command
  def spec do
    name = [name: [value_name: "NAME", required: true, help: "The name of the installation."]]

    [
      about: "List the installations that this machine knows, and choose the current one.",
      subcommands: [
        list: [
          name: "list",
          about: "List the installations that this machine knows. A * marks the current one.",
          flags: Output.json_flag()
        ],
        use: [
          name: "use",
          about: "Make an installation the current one.",
          args: name,
          flags: Output.json_flag()
        ],
        remove: [
          name: "remove",
          about:
            "Forget an installation. If it was the current one, no installation is current. " <>
              "This does not end its sign-in: run `ehosctl logout` first.",
          args: name,
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc """
  Runs `installations list`, `use` or `remove` on the configuration in `opts[:config_dir]`,
  by default `Ehosctl.Config.dir/1`'s. `use` and `remove` change it through
  `Ehosctl.Config.update/2`, so what another command changes at the same time is kept.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(path, parsed, opts) do
    dir = Keyword.get_lazy(opts, :config_dir, &Config.dir/0)

    run(path, parsed.args, dir)
  end

  defp run([:list], _args, dir) do
    with {:ok, config} <- Config.read(dir), do: {:ok, listed(config)}
  end

  defp run([:use], %{name: name}, dir) do
    with :ok <- refused_early(dir, name, &Config.make_current/2),
         {:ok, _read, _written} <- Config.update(dir, &Config.make_current(&1, name)) do
      {:ok, %{text: "#{name} is the current installation.", json: %{current: name}}}
    end
  end

  defp run([:remove], %{name: name}, dir) do
    with :ok <- refused_early(dir, name, &Config.remove/2),
         {:ok, _read, written} <- Config.update(dir, &Config.remove(&1, name)) do
      {:ok,
       %{
         text: "ehosctl forgot the installation #{name}.",
         json: %{removed: name, current: written.current}
       }}
    end
  end

  # A name the configuration does not hold is refused before the lock, so it leaves no directory
  # behind. One it holds, or a file that could not be read, which a write through a link may leave
  # half written for a moment, is looked for again under the lock (`Ehosctl.Config.update/2`).
  defp refused_early(dir, name, change) do
    case Config.read(dir) do
      {:ok, %Config{installations: installations} = config}
      when not is_map_key(installations, name) ->
        change.(config, name)

      _held_or_unread ->
        :ok
    end
  end

  defp listed(config) do
    rows =
      config.installations
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, installation} ->
        %{
          name: name,
          url: installation["url"],
          current: name == config.current,
          ca: Map.has_key?(installation, "ca")
        }
      end)

    %{text: table(rows), json: %{current: config.current, installations: rows}}
  end

  defp table([]),
    do:
      "No installations. An installation shows here after you sign in to it with `ehosctl login`."

  # Columns as kubectl's `config get-contexts` prints them: no borders, the current one
  # marked with an asterisk. CA says whether the installation's requests also trust the CA `login`
  # kept for it (T-14), or the system's alone.
  defp table(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        "CURRENT" => if(row.current, do: "*", else: ""),
        "NAME" => row.name,
        "URL" => row.url,
        "CA" => if(row.ca, do: "own", else: "system")
      }
    end)
    |> Output.table(["CURRENT", "NAME", "URL", "CA"])
  end
end
