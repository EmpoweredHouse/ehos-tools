defmodule Ehosctl.InitTest do
  # Not async: `with_io(:stderr)` captures stderr for every process, and one test changes the
  # working directory, which is the VM's, not the test's.
  use Ehosctl.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Template

  @moduletag :tmp_dir

  # What `init` says a name must be.
  @name_rules "The name has lowercase letters, digits and underscores. It starts with a " <>
                "letter and ends with a letter or a digit."

  # What is left to do once `shop/` is generated and not yet committed, after `cd shop`.
  @commit_by_hand """
      git init
      git symbolic-ref HEAD refs/heads/main
      git add -A
      git commit -m 'Generate the application with ehosctl init'
  """

  # What `init` prints on stdout once every step has run, for `shop`.
  @created """
  ✓ ehosctl created the application shop in shop/.
    Directory      shop/
    Erlang         #{Template.erlang()}
    Elixir         #{Template.elixir()}
    Name in EHOS   shop

  Start Docker before mix setup: it starts the PostgreSQL of the project in Docker.

  Next:
    cd shop
    mix setup
  """

  # T-27: a utility service's pipeline calls the shared workflow at the commit the tag of the
  # ehosctl release names, the tag beside it, and that workflow installs the ehosctl of that
  # release; a build between releases names the tag of the release to come.
  test "init --service calls the shared workflow at the commit of this ehosctl's release" do
    commit = String.duplicate("0123456789", 4)

    for {version, ref} <- [{"0.41.0", "#{commit} # v0.41.0"}, {"0.41.0-dev", "v0.41.0"}] do
      uses =
        for line <-
              String.split(
                Ehosctl.InitService.workflow(
                  "invoice-pdf",
                  elem(Ehosctl.InitService.ref(version, commit), 1)
                ),
                "\n"
              ),
            String.contains?(line, "uses:"),
            do: String.trim(line)

      assert uses == ["uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-service.yml@#{ref}"]
    end
  end

  test "refuses an option of a utility service without --service, and runs nothing" do
    assert ehosctl(["init", "shop", "--port", "9000", "--memory", "1Gi"], []) ==
             {2, "",
              "ehosctl: --memory and --port are for a utility service. Give --service as " <>
                "well, or leave them out.\n"}
  end

  test "runs every step under the pinned toolchain, with archives kept apart, and says each",
       %{tmp_dir: dir} do
    assert init(["shop"], archives: dir) ==
             {0, @created,
              """
              ==> Installing Erlang #{Template.erlang()} and Elixir #{Template.elixir()} with mise
              ==> Installing Hex for the generators
                * creating hex-2.5.1
              ==> Installing the generator phx_new #{Template.phx_new()}
              ==> Installing the generator igniter_new #{Template.igniter_new()}
              ==> Generating the Phoenix project shop
              ==> Keeping shop/ on the Igniter that ehos_app accepts
              ==> Installing ehos_app in shop/
              ==> Installing Hex for Elixir #{Template.elixir()}
              ==> Trusting shop/.tool-versions with mise
              ==> Formatting shop/
              ==> Committing shop/ on the branch main
              """, runs("shop", dir)}
  end

  test "installs ehos_app in the new project, from ehos-tools' subdirectory at the pinned commit" do
    requirement = "== #{Template.template_version()}"

    # The commit is the template's pin, which only its own test reads.
    assert {:ok,
            {:ehos_app, ^requirement,
             [github: "EmpoweredHouse/ehos-tools", sparse: "packages/ehos_app", ref: ref]}} =
             Template.install_dep()

    assert ref =~ ~r/\A[0-9a-f]{40}\z/
  end

  # Left to git, the branch is `init.defaultBranch`, else `master` in the git most Linux
  # distributions ship, and the generated CI publishes from `main` alone (ehos-tools#190).
  # `phx.new` has run `git init` already, so `git init --initial-branch=main` would be ignored.
  test "points the repository's unborn HEAD at main before the first commit", %{tmp_dir: dir} do
    {0, _stdout, _stderr, ran} = init(["shop"], archives: dir)

    assert for({"/bin/git", ["-C", "shop" | args], []} <- ran, do: args) == [
             ["init", "--quiet"],
             ["symbolic-ref", "HEAD", "refs/heads/main"],
             ["add", "--all"],
             ["commit", "--quiet", "--message", "Generate the application with ehosctl init"]
           ]
  end

  test "skips archives this ehosctl version already installed", %{tmp_dir: dir} do
    [toolchain, _hex, _phx_new, _igniter_new | project] = runs("shop", dir)

    {0, @created, stderr, ran} = init(["shop"], archives: archives_present(dir))
    assert ran == [toolchain | project]
    assert stderr == said_before("Not a step", archives_present: true)
  end

  test "reinstalls an archive whose install was interrupted", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "hex-2.5.1"))
    assert {0, @created, _stderr, ran} = init(["shop"], archives: dir)
    assert ran == runs("shop", dir)
  end

  test "takes a name with underscores as it is", %{tmp_dir: dir} do
    {0, stdout, stderr, ran} = init(["my_shop"], archives: dir)
    assert ran == runs("my_shop", dir)
    assert stderr == String.replace(said_before("Not a step"), "shop", "my_shop")

    assert stdout ==
             String.replace(@created, "shop", "my_shop")
             |> String.replace("EHOS   my_shop", "EHOS   my-shop")
  end

  test "writes a dash as an underscore, which an OTP application's name needs, and says so",
       %{tmp_dir: dir} do
    {0, stdout, stderr, ran} = init(["my-shop"], archives: dir)
    assert ran == runs("my_shop", dir)

    assert String.split(stderr, "==>", parts: 2) |> hd() ==
             """
             ! ehosctl generates my-shop as my_shop, in the directory my_shop/.
               The name of an OTP application has no dash. EHOS names the application my-shop.
             """

    assert stdout == """
           ✓ ehosctl created the application my_shop in my_shop/.
             Directory      my_shop/
             Erlang         #{Template.erlang()}
             Elixir         #{Template.elixir()}
             Name in EHOS   my-shop

           Start Docker before mix setup: it starts the PostgreSQL of the project in Docker.

           Next:
             cd my_shop
             mix setup
           """
  end

  test "prints its own help", %{tmp_dir: dir} do
    for flag <- ["--help", "-h"] do
      output = capture_io(fn -> assert Ehosctl.Init.run([flag], archives: dir) == 0 end)

      assert output == """
             Usage: ehosctl init NAME

             Create a new EHOS application in the directory NAME. NAME is the name of the OTP
             application. The name has lowercase letters, digits and underscores. It starts with a
             letter and ends with a letter or a digit. ehosctl writes a dash as an underscore. In
             EHOS, the application has dashes instead: `my_shop` is `my-shop` there.

             """
    end
  end

  test "a step that fails before the first commit gives the commands that finish the setup",
       %{tmp_dir: dir} do
    for {failing, count, step, command, said, to_do} <- [
          {"--if-missing", 9, "Installing Hex for Elixir #{Template.elixir()}",
           "mix local.hex --force --if-missing",
           "ehosctl generated shop/, but Hex is not installed for its Elixir.",
           "    mise trust shop/.tool-versions\n    cd shop\n    mix local.hex\n    mix format\n"},
          {"trust", 10, "Trusting shop/.tool-versions with mise",
           "mise trust shop/.tool-versions",
           "ehosctl generated shop/, but mise does not trust it yet.",
           "    mise trust shop/.tool-versions\n    cd shop\n    mix format\n"}
        ] do
      {3, "", stderr, ran} = init(["shop"], archives: dir, status: failing_at(failing))
      assert ran == Enum.take(runs("shop", dir), count)

      assert stderr ==
               said_before(step) <>
                 "==> #{step}\n" <>
                 "ehosctl: #{step} failed: `#{command}` exited with 3. #{said}\n" <>
                 "What to do:\n  Finish the setup by hand:\n" <>
                 String.replace(to_do, "    ", "  ") <>
                 String.replace(@commit_by_hand, "    ", "  ")
    end
  end

  test "a failed format says to correct what it printed, then gives the commands that finish",
       %{tmp_dir: dir} do
    {3, "", stderr, _ran} = init(["shop"], archives: dir, status: failing_at("format"))

    assert stderr ==
             said_before("Formatting shop/") <>
               """
               ==> Formatting shop/
               ehosctl: Formatting shop/ failed: `mix format` exited with 3. ehosctl generated shop/, but mix format failed in it.
               What to do:
                 Correct what mix format printed above. Then finish the setup by hand:
                 cd shop
                 mix format
                 git init
                 git symbolic-ref HEAD refs/heads/main
                 git add -A
                 git commit -m 'Generate the application with ehosctl init'
               """
  end

  test "a failure to commit says the project was generated, and how to commit it on main",
       %{tmp_dir: dir} do
    {3, "", stderr, ran} = init(["shop"], archives: dir, status: failing_at("commit"))
    assert ran == runs("shop", dir)

    assert stderr ==
             said_before("Committing shop/ on the branch main") <>
               """
               ==> Committing shop/ on the branch main
               ehosctl: Committing shop/ on the branch main failed: `git commit --quiet --message 'Generate the application with ehosctl init'` exited with 3. ehosctl generated shop/, but did not commit it.
               What to do:
                 Commit it by hand:
                 cd shop
                 git init
                 git symbolic-ref HEAD refs/heads/main
                 git add -A
                 git commit -m 'Generate the application with ehosctl init'
               """
  end

  test "a failure to install the template says the directory may be left half generated",
       %{tmp_dir: dir} do
    {3, "", stderr, ran} = init(["shop"], archives: dir, status: failing_at("run"))
    assert ran == Enum.take(runs("shop", dir), 8)

    assert stderr ==
             said_before("Installing ehos_app in shop/") <>
               """
               ==> Installing ehos_app in shop/
               ehosctl: Installing ehos_app in shop/ failed: `mix run --no-start -e #{EhosPlatform.Shell.word(Template.install_expression(elem(Template.install_dep(), 1)))}` exited with 3. shop/ can be half generated.
               What to do:
                 Remove shop/, then run the command again:
                 ehosctl init shop
               """
  end

  # `igniter.new` lets the project take the newest Igniter, and Igniter 0.9 is one that
  # `ehos_app` and `oidcc` refuse: `init` narrows the requirement before it installs `ehos_app`.
  test "narrows the requirement on Igniter that igniter.new wrote, and fails without it",
       %{tmp_dir: dir} do
    written = """
    defp deps do
      [
        {:igniter, "~> 0.6", only: [:dev, :test]},
        {:phoenix, "~> 1.8.1"}
      ]
    end
    """

    File.cd!(dir, fn ->
      File.write!("mix.exs", written)
      Code.eval_string(Template.igniter_expression())

      assert File.read!("mix.exs") ==
               String.replace(written, ~s("~> 0.6"), inspect(Template.igniter()))

      assert_raise RuntimeError, ~r/mix.exs has no \{:igniter, "~> 0.6"/, fn ->
        Code.eval_string(Template.igniter_expression())
      end
    end)
  end

  test "a failure to narrow Igniter says the directory may be left half generated",
       %{tmp_dir: dir} do
    {3, "", stderr, ran} = init(["shop"], archives: dir, status: failing_at("deps.update"))
    assert ran == Enum.take(runs("shop", dir), 7)

    assert stderr ==
             said_before("Keeping shop/") <>
               """
               ==> Keeping shop/ on the Igniter that ehos_app accepts
               ehosctl: Keeping shop/ on the Igniter that ehos_app accepts failed: `mix deps.update igniter` exited with 3. shop/ can be half generated.
               What to do:
                 Remove shop/, then run the command again:
                 ehosctl init shop
               """
  end

  test "says so when git is missing", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, git: nil) ==
             {1, "",
              "ehosctl: git: ehosctl cannot find it. ehosctl needs git to fetch the " <>
                "application template and to commit the new project. Install git, and run the " <>
                "command again.\n", []}
  end

  test "stops at the first step that fails, with its exit code, and says what mise needs",
       %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, status: 3) ==
             {3, "",
              """
              ==> Installing Erlang #{Template.erlang()} and Elixir #{Template.elixir()} with mise
              ehosctl: Installing Erlang #{Template.erlang()} and Elixir #{Template.elixir()} with mise failed: `mise install --quiet erlang@#{Template.erlang()} elixir@#{Template.elixir()}` exited with 3. mise could not install erlang@#{Template.erlang()} and elixir@#{Template.elixir()}.
              What to do:
                Read what mise printed above. If mise has no precompiled Erlang, install the tools that it needs to build Erlang from source: https://mise.jdx.dev/lang/erlang.html
              """, Enum.take(runs("shop", dir), 1)}
  end

  test "a failure before generation says nothing about a directory", %{tmp_dir: dir} do
    {3, "", stderr, ran} = init(["shop"], archives: dir, status: failing_at("archive.install"))
    assert ran == Enum.take(runs("shop", dir), 3)

    assert stderr ==
             said_before("Installing the generator phx_new #{Template.phx_new()}") <>
               "==> Installing the generator phx_new #{Template.phx_new()}\n" <>
               "ehosctl: Installing the generator phx_new #{Template.phx_new()} failed: `mix " <>
               "archive.install hex phx_new #{Template.phx_new()} --force` exited with 3.\n"
  end

  test "a failure during generation says the directory may be left half generated",
       %{tmp_dir: dir} do
    [toolchain, _hex, _phx_new, _igniter_new, generate | _project] = runs("shop", dir)

    {3, "", stderr, ran} =
      init(["shop"], archives: archives_present(dir), status: failing_at("igniter.new"))

    assert ran == [toolchain, generate]

    assert stderr ==
             said_before("Generating the Phoenix project shop", archives_present: true) <>
               """
               ==> Generating the Phoenix project shop
               ehosctl: Generating the Phoenix project shop failed: `mix igniter.new shop --with phx.new --with-args #{EhosPlatform.Shell.word(Template.phx_new_args())} --yes --no-installer-version-check --no-git` exited with 3. shop/ can be half generated.
               What to do:
                 Remove shop/, then run the command again:
                 ehosctl init shop
               """
  end

  test "a failure after generation says which setup step to finish by hand" do
    assert [trust] =
             "shop"
             |> Ehosctl.Init.steps("/bin/mise", "/archives")
             |> Enum.filter(&(&1.args |> List.first() == "trust"))

    assert trust == %{
             cmd: "/bin/mise",
             args: ["trust", "shop/.tool-versions"],
             env: [],
             say: "Trusting shop/.tool-versions with mise",
             skip_if: nil,
             on_failure: %Ehosctl.Failure{
               said: " ehosctl generated shop/, but mise does not trust it yet.",
               advice: "Finish the setup by hand:",
               to_do: [
                 "mise trust shop/.tool-versions",
                 "cd shop",
                 "mix format",
                 "git init",
                 "git symbolic-ref HEAD refs/heads/main",
                 "git add -A",
                 "git commit -m 'Generate the application with ehosctl init'"
               ]
             }
           }
  end

  test "refuses a name that is not an application name", %{tmp_dir: dir} do
    assert init(["My-Shop"], archives: dir) ==
             {2, "",
              "ehosctl: \"My-Shop\" is not a valid name for an application. #{@name_rules}\n", []}
  end

  test "refuses a name that ends with an underscore or a dash, as no DNS label does",
       %{tmp_dir: dir} do
    for name <- ["shop_", "shop-"] do
      assert init([name], archives: dir) ==
               {2, "",
                "ehosctl: #{inspect(name)} is not a valid name for an application. #{@name_rules}\n",
                []}
    end
  end

  test "refuses a directory that already exists", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      File.mkdir!("shop")

      assert init(["shop"], archives: dir) ==
               {1, "", "ehosctl: shop already exists. Give another name, or remove shop.\n", []}
    end)
  end

  test "says how to get mise when it is missing", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, mise: nil) ==
             {1, "",
              "ehosctl: mise: ehosctl cannot find it. ehosctl needs mise to run Erlang " <>
                "and Elixir at the pinned versions. Install mise: " <>
                "https://mise.jdx.dev/installing-mise.html\n", []}
  end

  # Runs `init` with `argv`, returning its exit code, its stdout, its stderr and the programs it
  # ran, as `{cmd, args, env}`. `:status` is one exit code for every step, or a function of the
  # step's arguments; mise and git are where `:mise` and `:git` say, `nil` for none. Hex's install
  # for the generators prints a line, as Mix does.
  defp init(argv, opts) do
    parent = self()
    status = Keyword.get(opts, :status, 0)

    stub(Ehosctl.RunnerMock, :streamed, fn cmd, args, env, acc, printed ->
      send(parent, {:ran, cmd, args, env})

      acc =
        if List.last(args) == "--force" and "local.hex" in args,
          do: printed.("* creating hex-2.5.1\n", acc),
          else: acc

      {if(is_function(status), do: status.(args), else: status), acc}
    end)

    found = %{
      "mise" => Keyword.get(opts, :mise, "/bin/mise"),
      "git" => Keyword.get(opts, :git, "/bin/git")
    }

    stub(Ehosctl.OSMock, :find_executable, &Map.get(found, &1))

    opts = Keyword.drop(opts, [:status, :mise, :git])

    {{code, stdout}, stderr} =
      with_io(:stderr, fn -> with_io(fn -> Ehosctl.Init.run(argv, opts) end) end)

    {code, stdout, stderr, ran()}
  end

  # What `init` says on stderr for `shop` before the step `step`, the generators' archives
  # installed unless `:archives_present`.
  defp said_before(step, opts \\ []) do
    generators = [
      "==> Installing Hex for the generators\n  * creating hex-2.5.1\n",
      "==> Installing the generator phx_new #{Template.phx_new()}\n",
      "==> Installing the generator igniter_new #{Template.igniter_new()}\n"
    ]

    ["==> Installing Erlang #{Template.erlang()} and Elixir #{Template.elixir()} with mise\n"]
    |> Kernel.++(if opts[:archives_present], do: [], else: generators)
    |> Kernel.++([
      "==> Generating the Phoenix project shop\n",
      "==> Keeping shop/ on the Igniter that ehos_app accepts\n",
      "==> Installing ehos_app in shop/\n",
      "==> Installing Hex for Elixir #{Template.elixir()}\n",
      "==> Trusting shop/.tool-versions with mise\n",
      "==> Formatting shop/\n",
      "==> Committing shop/ on the branch main\n"
    ])
    |> Enum.take_while(&(not String.starts_with?(&1, "==> " <> step)))
    |> Enum.join()
  end

  defp ran do
    receive do
      {:ran, cmd, args, env} -> [{cmd, args, env} | ran()]
    after
      0 -> []
    end
  end

  # Every program `init` runs for the application `name`, with archives in `archives`, in order.
  defp runs(name, archives) do
    tools = ["erlang@#{Template.erlang()}", "elixir@#{Template.elixir()}"]
    exec = ["exec" | tools] ++ ["--"]
    tools_first = {"MISE_ACTIVATE_AGGRESSIVE", "1"}
    with_archives = [{"MIX_ARCHIVES", archives}, tools_first]
    {:ok, dep} = Template.install_dep()

    [
      {"/bin/mise", ["install", "--quiet" | tools], [tools_first]},
      {"/bin/mise", exec ++ ["mix", "local.hex", "--force"], with_archives},
      {"/bin/mise",
       exec ++ ["mix", "archive.install", "hex", "phx_new", Template.phx_new(), "--force"],
       with_archives},
      {"/bin/mise",
       exec ++
         ["mix", "archive.install", "hex", "igniter_new", Template.igniter_new(), "--force"],
       with_archives},
      {"/bin/mise",
       exec ++
         [
           "mix",
           "igniter.new",
           name,
           "--with",
           "phx.new",
           "--with-args",
           Template.phx_new_args(),
           "--yes",
           "--no-installer-version-check",
           "--no-git"
         ], with_archives},
      {"/bin/mise", ["-C", name | exec] ++ ["elixir", "-e", Template.igniter_expression()],
       with_archives},
      {"/bin/mise", ["-C", name | exec] ++ ["mix", "deps.update", "igniter"], with_archives},
      {"/bin/mise",
       ["-C", name | exec] ++
         ["mix", "run", "--no-start", "-e", Template.install_expression(dep)], with_archives},
      {"/bin/mise", exec ++ ["mix", "local.hex", "--force", "--if-missing"], [tools_first]},
      {"/bin/mise", ["trust", "#{name}/.tool-versions"], []},
      # Formatted before the first commit, so CI's `mix format` gate passes as generated
      # (ehos-tools#574).
      {"/bin/mise", ["-C", name | exec] ++ ["mix", "format"], [tools_first]},
      {"/bin/git", ["-C", name, "init", "--quiet"], []},
      {"/bin/git", ["-C", name, "symbolic-ref", "HEAD", "refs/heads/main"], []},
      {"/bin/git", ["-C", name, "add", "--all"], []},
      {"/bin/git",
       [
         "-C",
         name,
         "commit",
         "--quiet",
         "--message",
         "Generate the application with ehosctl init"
       ], []}
    ]
  end

  # A step whose arguments hold `arg` exits with 3, and every other with 0.
  defp failing_at(arg), do: fn args -> if arg in args, do: 3, else: 0 end

  defp archives_present(dir) do
    for archive <- [
          "hex-2.5.1",
          "phx_new-#{Template.phx_new()}",
          "igniter_new-#{Template.igniter_new()}"
        ] do
      File.mkdir_p!(Path.join([dir, archive, archive, "ebin"]))
    end

    dir
  end
end
