defmodule Mix.Tasks.EhosApp.InstallCase do
  # What every test of `mix ehos_app.install` runs the installer with and reads its result
  # by: the test project, the installer composed on it, and the helpers more than one area
  # of the installer's tests uses.
  @moduledoc false

  use ExUnit.CaseTemplate

  import Igniter.Test

  alias Mix.Tasks.EhosApp.Install

  using do
    quote do
      import Igniter.Test
      import Mix.Tasks.EhosApp.InstallCase

      alias Mix.Tasks.EhosApp.Install
    end
  end

  # EHOS's schema of the version the installer writes, as eh_os_contract_auth carries it, which
  # the project's comment names: eh-os-contract's release this version pins, `v0.12.0`.
  @schema "test/fixtures/schemas/ehos.yaml.v7.json"

  def install(argv \\ []) do
    phx_test_project()
    |> Igniter.compose_task("ehos_app.install", argv)
  end

  # After `apply_igniter!/1`, the test project reads back only `**/*.*`, which leaves out
  # `Dockerfile` and every path under a dot directory; those are in its `test_files`.
  def content(igniter, path) do
    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Rewrite.Source.get(source, :content)
      {:error, _} -> Map.fetch!(igniter.assigns.test_files, path)
    end
  end

  def installed(argv \\ []), do: install(argv) |> apply_igniter!()

  def plugin(name), do: Enum.find(Install.plugins(), &(&1.name == name))

  def ehos_yaml(igniter), do: igniter |> content("ehos.yaml") |> YamlElixir.read_from_string!()

  # A file of the test project, as the developer has it before the installer runs.
  def replace_file(igniter, path, content) do
    Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fn _ -> content end))
  end

  # A file of the test project as it is, unformatted, read in as one already on disk.
  def with_file(igniter, path, content) do
    igniter
    |> Igniter.assign(:test_files, Map.put(igniter.assigns.test_files, path, content))
    |> Igniter.include_existing_file(path)
  end

  # The children of an application module, as written.
  def children(application) do
    [_, rest] = String.split(application, "children = [", parts: 2)
    [children, _] = String.split(rest, "\n    ]", parts: 2)
    children
  end

  # The literal arguments of every call to one of `names` in a module's source, outermost first.
  def calls(source, names) do
    names = List.wrap(names)

    {_, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          if name in names, do: {node, [args | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  def schema(_igniter), do: @schema |> File.read!() |> JSON.decode!() |> JSV.build!()

  def schema_title, do: @schema |> File.read!() |> JSON.decode!() |> Map.fetch!("title")

  # The generated configuration as Mix reads it, from files written out of the in-memory
  # project: `config.exs` imports the environment's own file.
  def read_config(igniter, env) do
    dir = Path.join(System.tmp_dir!(), "ehos_app_config_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for source <- igniter.rewrite,
        path = Rewrite.Source.get(source, :path),
        String.starts_with?(path, "config/") do
      File.mkdir_p!(Path.join(dir, Path.dirname(path)))
      File.write!(Path.join(dir, path), Rewrite.Source.get(source, :content))
    end

    Config.Reader.read!(Path.join(dir, "config/config.exs"), env: env)
  end
end
