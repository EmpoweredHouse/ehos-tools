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
    name = [name: [value_name: "NAME", required: true, help: "The installation's name."]]

    [
      about: "List the installations you know, and choose the current one.",
      subcommands: [
        list: [
          name: "list",
          about: "List the installations you know, marking the current one.",
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
            "Forget an installation. None is current if it was. Its sign-in is not ended: " <>
              "run `ehosctl logout` first.",
          args: name,
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc """
  Runs `installations list`, `use` or `remove` on the configuration in `opts[:config_dir]`,
  by default `Ehosctl.Config.dir/1`'s.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call(path, parsed, opts) do
    dir = Keyword.get_lazy(opts, :config_dir, &Config.dir/0)

    with {:ok, config} <- Config.read(dir) do
      run(path, parsed.args, config, dir)
    end
  end

  defp run([:list], _args, config, _dir) do
    rows =
      config.installations
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, installation} ->
        %{name: name, url: installation["url"], current: name == config.current}
      end)

    {:ok, %{text: table(rows), json: %{current: config.current, installations: rows}}}
  end

  defp run([:use], %{name: name}, config, dir) do
    with {:ok, config} <- Config.make_current(config, name),
         :ok <- Config.write(config, dir) do
      {:ok, %{text: "#{name} is the current installation.", json: %{current: name}}}
    end
  end

  defp run([:remove], %{name: name}, config, dir) do
    with {:ok, config} <- Config.remove(config, name),
         :ok <- Config.write(config, dir) do
      {:ok, %{text: "Forgot #{name}.", json: %{removed: name, current: config.current}}}
    end
  end

  defp table([]), do: "No installations yet."

  # Columns as kubectl's `config get-contexts` prints them: no borders, the current one
  # marked with an asterisk.
  @columns ["CURRENT", "NAME", "URL"]

  defp table(rows) do
    rows
    |> Enum.map(fn row ->
      %{"CURRENT" => if(row.current, do: "*", else: ""), "NAME" => row.name, "URL" => row.url}
    end)
    |> Owl.Table.new(
      border_style: :none,
      padding_x: 1,
      max_width: :infinity,
      sort_columns: fn a, b -> index(a) <= index(b) end
    )
    |> Owl.Data.to_chardata()
    |> IO.chardata_to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  defp index(column), do: Enum.find_index(@columns, &(&1 == column))
end
