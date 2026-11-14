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

  # What `init` adds to a step's failure once `shop/` is generated and not yet committed.
  @finish_by_hand "Then, in `shop/`, run `mix format`, `git init`, " <>
                    "`git symbolic-ref HEAD refs/heads/main`, `git add -A` and `git commit`."

  # T-27: a utility service's pipeline calls the shared workflow at the commit the tag of the
  # ehosctl release names, the tag beside it, and that workflow installs the ehosctl of that
  # release; a build between releases names the tag of the release to come.
  test "init --service calls the shared workflow at the commit of this ehosctl's release" do
    commit = String.duplicate("0123456789", 4)

    for {version, ref} <- [{"0.41.0", "#{commit} # v0.41.0"}, {"0.41.0-dev", "v0.41.0"}] do
      uses =
        for line <-
              String.split(Ehosctl.InitService.workflow("invoice-pdf", version, commit), "\n"),
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

  test "runs every step under the pinned toolchain, with archives kept apart", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir) == {0, "", runs("shop", dir)}
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
    {0, "", ran} = init(["shop"], archives: dir)

    assert for({"/bin/git", ["-C", "shop" | args], []} <- ran, do: args) == [
             ["init", "--quiet"],
             ["symbolic-ref", "HEAD", "refs/heads/main"],
             ["add", "--all"],
             ["commit", "--quiet", "--message", "Generate the application with ehosctl init"]
           ]
  end

  test "skips archives this ehosctl version already installed", %{tmp_dir: dir} do
    [toolchain, _hex, _phx_new, _igniter_new | project] = runs("shop", dir)

    assert init(["shop"], archives: archives_present(dir)) ==
             {0, "", [toolchain | project]}
  end

  test "reinstalls an archive whose install was interrupted", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "hex-2.5.1"))
    assert init(["shop"], archives: dir) == {0, "", runs("shop", dir)}
  end

  test "takes a name with underscores as it is", %{tmp_dir: dir} do
    assert init(["my_shop"], archives: dir) == {0, "", runs("my_shop", dir)}
  end

  test "writes a dash as an underscore, which an OTP application's name needs, and says so",
       %{tmp_dir: dir} do
    stdout =
      capture_io(fn ->
        assert init(["my-shop"], archives: dir) == {0, "", runs("my_shop", dir)}
      end)

    assert stdout ==
             "ehosctl init: The name of an OTP application has no dash. ehosctl generates " <>
               "my-shop as my_shop, in the directory my_shop/. EHOS names the application " <>
               "my-shop.\n"
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

  test "a step that fails before the first commit says to format the project and commit it on main",
       %{tmp_dir: dir} do
    for {failing, count, says} <- [
          {"--if-missing", 7,
           "ehosctl generated `shop/`, but Hex is not installed for its Elixir. " <>
             "Run `mise trust shop/.tool-versions`, then run `mix local.hex` in it."},
          {"trust", 8,
           "ehosctl generated `shop/`, but mise does not trust it yet. " <>
             "Run `mise trust shop/.tool-versions`."},
          {"format", 9,
           "ehosctl generated `shop/`, but `mix format` failed in it. Fix what it says."}
        ] do
      ran = Enum.take(runs("shop", dir), count)
      {_cmd, args, _env} = List.last(ran)

      assert init(["shop"], archives: dir, status: failing_at(failing)) ==
               {3,
                "ehosctl init: `#{Enum.join(["mise" | args], " ")}` stopped with exit code 3.\n" <>
                  "ehosctl init: #{says} #{@finish_by_hand}\n", ran}
    end
  end

  test "a failure to commit says the project was generated, and how to commit it on main",
       %{tmp_dir: dir} do
    ran = runs("shop", dir)

    assert init(["shop"], archives: dir, status: failing_at("commit")) ==
             {3,
              "ehosctl init: `git -C shop commit --quiet --message Generate the application " <>
                "with ehosctl init` stopped with exit code 3.\n" <>
                "ehosctl init: ehosctl generated `shop/`, but did not commit it. In `shop/`, " <>
                "run `git init`, `git symbolic-ref HEAD refs/heads/main`, `git add -A` and " <>
                "`git commit`.\n", ran}
  end

  test "a failure to install the template says the directory may be left half generated",
       %{tmp_dir: dir} do
    ran = Enum.take(runs("shop", dir), 6)
    {_cmd, args, _env} = List.last(ran)

    assert init(["shop"], archives: dir, status: failing_at("run")) ==
             {3,
              "ehosctl init: `#{Enum.join(["mise" | args], " ")}` stopped with exit code 3.\n" <>
                "ehosctl init: `shop/` can be half generated. Remove it before you run " <>
                "`ehosctl init shop` again.\n", ran}
  end

  test "says so when git is missing", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, git: nil) ==
             {1,
              "ehosctl init: git: ehosctl cannot find it. ehosctl needs git to fetch the " <>
                "application template and to commit the new project. Install git, and run the " <>
                "command again.\n", []}
  end

  test "stops at the first step that fails, with its exit code", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, status: 3) ==
             {3, toolchain_failed(), Enum.take(runs("shop", dir), 1)}
  end

  test "a failed toolchain install says what mise does where it has no precompiled Erlang",
       %{tmp_dir: dir} do
    {3, stderr, _ran} = init(["shop"], archives: dir, status: 3)

    assert stderr == toolchain_failed()
  end

  test "a failure before generation says nothing about a directory", %{tmp_dir: dir} do
    ran = Enum.take(runs("shop", dir), 3)
    {_cmd, args, _env} = List.last(ran)

    assert init(["shop"], archives: dir, status: failing_at("archive.install")) ==
             {3, "ehosctl init: `#{Enum.join(["mise" | args], " ")}` stopped with exit code 3.\n",
              ran}
  end

  test "a failure during generation says the directory may be left half generated",
       %{tmp_dir: dir} do
    [toolchain, _hex, _phx_new, _igniter_new, generate | _project] = runs("shop", dir)
    {_cmd, args, _env} = generate

    assert init(["shop"], archives: archives_present(dir), status: failing_at("igniter.new")) ==
             {3,
              "ehosctl init: `#{Enum.join(["mise" | args], " ")}` stopped with exit code 3.\n" <>
                "ehosctl init: `shop/` can be half generated. Remove it before you run " <>
                "`ehosctl init shop` again.\n", [toolchain, generate]}
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
             skip_if: nil,
             on_failure:
               "ehosctl generated `shop/`, but mise does not trust it yet. " <>
                 "Run `mise trust shop/.tool-versions`. #{@finish_by_hand}"
           }
  end

  test "refuses a name that is not an application name", %{tmp_dir: dir} do
    assert init(["My-Shop"], archives: dir) ==
             {1,
              "ehosctl init: \"My-Shop\" is not a valid name for an application. #{@name_rules}\n",
              []}
  end

  test "refuses a name that ends with an underscore or a dash, as no DNS label does",
       %{tmp_dir: dir} do
    for name <- ["shop_", "shop-"] do
      assert init([name], archives: dir) ==
               {1,
                "ehosctl init: #{inspect(name)} is not a valid name for an application. #{@name_rules}\n",
                []}
    end
  end

  test "refuses a directory that already exists", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      File.mkdir!("shop")

      assert init(["shop"], archives: dir) ==
               {1, "ehosctl init: shop already exists. Give another name, or remove shop.\n", []}
    end)
  end

  test "says how to get mise when it is missing", %{tmp_dir: dir} do
    assert init(["shop"], archives: dir, mise: nil) ==
             {1,
              "ehosctl init: mise: ehosctl cannot find it. ehosctl needs mise to run Erlang " <>
                "and Elixir at the pinned versions. Install mise: " <>
                "https://mise.jdx.dev/installing-mise.html\n", []}
  end

  # Runs `init` with `argv`, returning its exit code, its stderr and the programs it ran, as
  # `{cmd, args, env}`. `:status` is one exit code for every step, or a function of the step's
  # arguments; mise and git are where `:mise` and `:git` say, `nil` for none.
  defp init(argv, opts) do
    parent = self()
    status = Keyword.get(opts, :status, 0)

    stub(Ehosctl.RunnerMock, :interactive, fn cmd, args, env ->
      send(parent, {:ran, cmd, args, env})
      if is_function(status), do: status.(args), else: status
    end)

    found = %{
      "mise" => Keyword.get(opts, :mise, "/bin/mise"),
      "git" => Keyword.get(opts, :git, "/bin/git")
    }

    stub(Ehosctl.OSMock, :find_executable, &Map.get(found, &1))

    opts = Keyword.drop(opts, [:status, :mise, :git])
    {code, stderr} = with_io(:stderr, fn -> Ehosctl.Init.run(argv, opts) end)
    {code, stderr, ran()}
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

  # What `init` says when the toolchain could not be installed.
  defp toolchain_failed do
    tools = "erlang@#{Template.erlang()} elixir@#{Template.elixir()}"

    "ehosctl init: `mise install --quiet #{tools}` stopped with exit code 3.\n" <>
      "ehosctl init: mise could not install erlang@#{Template.erlang()} and " <>
      "elixir@#{Template.elixir()}. If mise has no precompiled Erlang, it builds Erlang " <>
      "from source: https://mise.jdx.dev/lang/erlang.html\n"
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
