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
  # the project's comment names: eh-os-contract's release this version pins, `v0.14.0`.
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
  # project, under the calling test's `tmp_dir`: `config.exs` imports the environment's own file.
  # Each call writes to a directory of its own, so a test can read more than one project.
  def read_config(igniter, env, tmp_dir) do
    dir = Path.join(tmp_dir, "config_#{System.unique_integer([:positive])}")

    for source <- igniter.rewrite,
        path = Rewrite.Source.get(source, :path),
        String.starts_with?(path, "config/") do
      File.mkdir_p!(Path.join(dir, Path.dirname(path)))
      File.write!(Path.join(dir, path), Rewrite.Source.get(source, :content))
    end

    Config.Reader.read!(Path.join(dir, "config/config.exs"), env: env)
  end

  # The project as it is, applied, and the installer run on it: a second run, or a first on a
  # project the test has shaped.
  def install_on(igniter, argv \\ []) do
    igniter
    |> apply_igniter!()
    |> Igniter.compose_task("ehos_app.install", argv)
  end

  def install_again(igniter, argv \\ []), do: igniter |> install_on(argv) |> apply_igniter!()

  # A file of the test project, changed by `fun` before the installer runs.
  def edit_file(igniter, path, fun),
    do: Igniter.update_file(igniter, path, &Rewrite.Source.update(&1, :content, fun))

  # A dependency in the project's `mix.exs` as Mix reads it, or `nil` when it has none.
  def dep(igniter, name) do
    case Igniter.Project.Deps.get_dep(igniter, name) do
      {:ok, nil} -> nil
      {:ok, source} -> source |> Code.eval_string() |> elem(0)
    end
  end

  # The lines of `text` from the line `first` through the next line `last`, as the file has them.
  def lines(text, first, last) do
    [^first | rest] = text |> String.split("\n") |> Enum.drop_while(&(&1 != first))
    {inside, [^last | _]} = Enum.split_while(rest, &(&1 != last))
    Enum.join([first | inside] ++ [last, ""], "\n")
  end

  def lines_with(text, fragment),
    do: text |> String.split("\n") |> Enum.filter(&String.contains?(&1, fragment))

  def lines_starting(text, start),
    do: text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, start))

  # The notices or warnings that begin with `beginning`, each compared whole by the test.
  def messages_starting(messages, beginning),
    do: Enum.filter(messages, &String.starts_with?(&1, beginning))

  # The steps of the project's `precommit` alias, as `mix.exs` has them.
  def precommit(igniter),
    do: igniter |> content("mix.exs") |> lines("      precommit: [", "      ]")

  # What the installer says once it has written a new project.
  def ready_notice do
    """
    EHOS: the project is ready. Start a database, then:

        mix ecto.setup
        mix precommit

    eh_os_contract and ehos_design are read from private repositories. Build the image
    with a GitHub token that can read both, as a build secret. Every dependency's mix.exs
    runs where the token is, so prefer a fine-grained token that can read those two
    repositories alone to the one `gh auth token` prints. Set GITHUB_TOKEN from where you
    keep it rather than typing it, which leaves it in the shell's history, then:

        docker build --secret id=github_token,env=GITHUB_TOKEN .

    The CI workflow reads them through a GitHub App installed on eh-os-contract and
    ehos-tools with read access to their contents. Give the repository the App's ID and
    private key:

        gh secret set EHOS_CI_APP_ID --body <the App's ID>
        gh secret set EHOS_CI_APP_PRIVATE_KEY < <the App's private key>.pem
    """
  end

  # What it says of a project with no contract, which keeps no lock.
  def no_contract_notice do
    """
    No module under lib/ uses EhOsContract.Contract, so the project keeps no
    eh_os_contract.lock, and `mix precommit` does not run
    `mix eh_os_contract.schema --check`. Once it has a contract, before any of its events
    changes, run `mix eh_os_contract.schema`, commit eh_os_contract.lock, and run the
    installer again: it adds the check.
    """
  end

  # What it says of an `eh_os_contract_auth` on a source of the project's own.
  def auth_left_warning do
    """
    eh_os_contract_auth was on a source or a commit of eh-os-contract that this version of ehos_app
    does not know, so it was left as it is. This ehos_app is written for eh-os-contract's
    release v0.14.0 (412f0cfac338a417c6868cd842d4e0d70adbe16b); signing people in through
    EHOS needs da9f56f3da4f1d5737bf0b5fc917254b7b2a6dfb or a later commit.
    """
  end

  def notices_about(igniter, fragment),
    do: Enum.filter(igniter.notices, &String.contains?(&1, fragment))

  # Every run of lines in `content` from one that starts with `first` to the next that is `last`,
  # each with its line ending.
  def sections(content, first, last) do
    content
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn
        line, nil ->
          if String.starts_with?(line, first), do: {:cont, [line]}, else: {:cont, nil}

        line, lines ->
          if String.trim_trailing(line, "\r") == last,
            do: {:cont, Enum.join(Enum.reverse([line | lines]), "\n") <> "\n", nil},
            else: {:cont, [line | lines]}
      end,
      fn _unfinished -> {:cont, nil} end
    )
  end

  # The lines of a file that begin, after their indentation, as `beginning` does.
  def trimmed_lines_starting(igniter, path, beginning) do
    igniter
    |> content(path)
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, beginning))
  end
end
