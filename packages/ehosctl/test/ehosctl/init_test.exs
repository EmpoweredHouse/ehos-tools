defmodule Ehosctl.InitTest do
  # Not async: one test changes the working directory, which is the VM's, not the test's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Template

  @moduletag :tmp_dir

  defp init(argv, opts) do
    parent = self()

    # `:status` is one exit code for every step, or a function of the step's arguments.
    status = Keyword.get(opts, :status, 0)

    runner = fn cmd, args, env ->
      send(parent, {:ran, cmd, args, env})
      if is_function(status), do: status.(args), else: status
    end

    opts = Keyword.merge([mise: "/bin/mise", git: "/bin/git", runner: runner], opts)
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

  test "runs every step under the pinned toolchain, with archives kept apart", %{tmp_dir: dir} do
    {0, "", ran} = init(["shop"], archives: dir)

    assert [toolchain, hex, phx_new, igniter_new, generate, install, project_hex, trust | commit] =
             ran

    assert toolchain ==
             {"/bin/mise",
              [
                "install",
                "--quiet",
                "erlang@#{Template.erlang()}",
                "elixir@#{Template.elixir()}"
              ], []}

    for {cmd, args, _env} <- [hex, phx_new, igniter_new, generate, project_hex] do
      assert cmd == "/bin/mise"
      assert ["exec", erlang, elixir, "--", "mix" | _] = args
      assert erlang == "erlang@#{Template.erlang()}"
      assert elixir == "elixir@#{Template.elixir()}"
    end

    for {_, _, env} <- [hex, phx_new, igniter_new, generate, install] do
      assert env == [{"MIX_ARCHIVES", dir}]
    end

    {_, generate, _} = generate
    assert ["mix", "igniter.new", "shop", "--with", "phx.new" | _] = Enum.drop(generate, 4)
    assert "--no-git" in generate
    refute "--install" in generate

    {:ok, dep} = Template.install_dep()

    assert {"/bin/mise",
            ["-C", "shop", "exec", _, _, "--", "mix", "run", "--no-start", "-e", code], _} =
             install

    assert code == Template.install_expression(dep)

    assert {_, args, []} = project_hex
    assert Enum.take(args, -3) == ["local.hex", "--force", "--if-missing"]
    assert trust == {"/bin/mise", ["trust", "shop/.tool-versions"], []}

    assert [
             {"/bin/git", ["-C", "shop", "init", "--quiet"], []},
             {"/bin/git", ["-C", "shop", "add", "--all"], []},
             {"/bin/git", ["-C", "shop", "commit", "--quiet", "--message", _], []}
           ] = commit
  end

  test "installs ehos_app in the new project, from ehos-tools' subdirectory at the pinned commit" do
    {:ok, {:ehos_app, opts}} = Template.install_dep()

    assert opts[:github] == "EmpoweredHouse/ehos-tools"
    assert opts[:sparse] == "packages/ehos_app"
    assert opts[:ref] =~ ~r/\A[0-9a-f]{40}\z/
    refute opts[:tag]
  end

  test "a failure to commit says the project was generated, and how to commit it",
       %{tmp_dir: dir} do
    fail_commit = fn args -> if "commit" in args, do: 3, else: 0 end
    {3, stderr, _ran} = init(["shop"], archives: dir, status: fail_commit)

    assert stderr =~ "`shop/` was generated, but not committed"
  end

  test "a failure to install the template says the directory may be left half generated",
       %{tmp_dir: dir} do
    fail_install = fn args -> if "run" in args, do: 3, else: 0 end
    {3, stderr, _ran} = init(["shop"], archives: dir, status: fail_install)

    assert stderr =~ "`shop/` may be left half generated"
  end

  test "says so when git is missing", %{tmp_dir: dir} do
    {1, stderr, []} = init(["shop"], archives: dir, git: nil)
    assert stderr =~ "git is needed"
  end

  test "skips archives this ehosctl version already installed", %{tmp_dir: dir} do
    {0, "", [_toolchain, {_, args, _} | _project_setup]} =
      init(["shop"], archives: archives_present(dir))

    assert "igniter.new" in args
  end

  test "reinstalls an archive whose install was interrupted", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "hex-2.5.1"))
    {0, "", [_toolchain, {_, args, _} | _]} = init(["shop"], archives: dir)
    assert Enum.take(args, -3) == ["mix", "local.hex", "--force"]
  end

  test "stops at the first step that fails, with its exit code", %{tmp_dir: dir} do
    {3, stderr, [_only_one]} = init(["shop"], archives: dir, status: 3)
    assert stderr =~ "exited with 3"
  end

  test "a failed toolchain install says what mise does where it has no precompiled Erlang",
       %{tmp_dir: dir} do
    {3, stderr, [_toolchain]} = init(["shop"], archives: dir, status: 3)
    assert stderr =~ "`mise install --quiet erlang@#{Template.erlang()}"
    assert stderr =~ "https://mise.jdx.dev/lang/erlang.html"
    refute stderr =~ "shop/"
  end

  test "a failure before generation says nothing about a directory", %{tmp_dir: dir} do
    fail_archives = fn args -> if "archive.install" in args, do: 3, else: 0 end

    {3, stderr, [_toolchain, _hex, _phx_new]} =
      init(["shop"], archives: dir, status: fail_archives)

    assert stderr =~ "archive.install hex phx_new"
    refute stderr =~ "shop/"
  end

  test "a failure during generation says the directory may be left half generated",
       %{tmp_dir: dir} do
    fail_generation = fn args -> if "igniter.new" in args, do: 3, else: 0 end

    {3, stderr, [_toolchain, _generate]} =
      init(["shop"], archives: archives_present(dir), status: fail_generation)

    assert stderr =~ "`shop/` may be left half generated"
    assert stderr =~ "before running `ehosctl init shop` again"
  end

  test "a failure after generation says which setup step to finish by hand" do
    [trust] =
      "shop"
      |> Ehosctl.Init.steps("/bin/mise", "/archives")
      |> Enum.filter(&(&1.args |> List.first() == "trust"))

    assert trust.on_failure =~ "`shop/` was generated"
    assert trust.on_failure =~ "mise trust shop/.tool-versions"
  end

  test "refuses a name that is not an application name", %{tmp_dir: dir} do
    {1, stderr, []} = init(["My-Shop"], archives: dir)
    assert stderr =~ "not a valid application name"
  end

  test "takes a name with underscores as it is", %{tmp_dir: dir} do
    {0, "", ran} = init(["my_shop"], archives: dir)
    assert Enum.any?(ran, fn {_cmd, args, _env} -> "my_shop" in args end)
  end

  test "writes a dash as an underscore, which an OTP application's name needs, and says so",
       %{tmp_dir: dir} do
    stdout =
      capture_io(fn ->
        {0, "", ran} = init(["my-shop"], archives: dir)
        send(self(), {:ran_args, Enum.flat_map(ran, fn {_cmd, args, _env} -> args end)})
      end)

    assert_received {:ran_args, args}
    assert "my_shop" in args
    refute "my-shop" in args
    assert stdout =~ "generated as my_shop, in the directory my_shop/. EHOS names it my-shop."
  end

  test "refuses a name that ends with an underscore or a dash, as no DNS label does",
       %{tmp_dir: dir} do
    for name <- ["shop_", "shop-"] do
      {1, stderr, []} = init([name], archives: dir)
      assert stderr =~ "ending with a letter or a digit"
    end
  end

  test "refuses a directory that already exists", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      File.mkdir!("shop")
      {1, stderr, []} = init(["shop"], archives: dir)
      assert stderr =~ "already exists"
    end)
  end

  test "prints its own help", %{tmp_dir: dir} do
    for flag <- ["--help", "-h"] do
      output = capture_io(fn -> assert Ehosctl.Init.run([flag], archives: dir) == 0 end)
      assert output =~ "Usage: ehosctl init <name>"
    end
  end

  test "says how to get mise when it is missing", %{tmp_dir: dir} do
    {1, stderr, []} = init(["shop"], archives: dir, mise: nil)
    assert stderr =~ "https://mise.jdx.dev/installing-mise.html"
  end
end
