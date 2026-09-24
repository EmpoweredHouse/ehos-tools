defmodule Ehosctl.InitTest do
  # Not async: one test changes the working directory, which is the VM's, not the test's.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ehosctl.Template

  @moduletag :tmp_dir

  defp init(argv, opts) do
    parent = self()

    runner = fn cmd, args, cmd_opts ->
      send(parent, {:ran, cmd, args, cmd_opts[:env]})
      {"", Keyword.get(opts, :status, 0)}
    end

    opts = Keyword.merge([mise: "/bin/mise", runner: runner], opts)
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

  test "runs every step under the pinned toolchain, with archives kept apart", %{tmp_dir: dir} do
    {0, "", ran} = init(["shop"], archives: dir)

    assert [hex, phx_new, igniter_new, generate, project_hex, trust] = ran

    for {cmd, args, _env} <- [hex, phx_new, igniter_new, generate, project_hex] do
      assert cmd == "/bin/mise"
      assert ["exec", erlang, elixir, "--", "mix" | _] = args
      assert erlang == "erlang@#{Template.erlang()}"
      assert elixir == "elixir@#{Template.elixir()}"
    end

    for {_, _, env} <- [hex, phx_new, igniter_new, generate] do
      assert env == [{"MIX_ARCHIVES", dir}]
    end

    {_, generate, _} = generate
    assert ["mix", "igniter.new", "shop", "--with", "phx.new" | _] = Enum.drop(generate, 4)
    assert Template.install_spec() in generate

    assert {_, args, []} = project_hex
    assert Enum.take(args, -3) == ["local.hex", "--force", "--if-missing"]
    assert trust == {"/bin/mise", ["trust", "shop/.tool-versions"], []}
  end

  test "skips archives this ehosctl version already installed", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "hex-2.5.1"))
    File.mkdir_p!(Path.join(dir, "phx_new-#{Template.phx_new()}"))
    File.mkdir_p!(Path.join(dir, "igniter_new-#{Template.igniter_new()}"))

    {0, "", [{_, args, _} | _project_setup]} = init(["shop"], archives: dir)
    assert "igniter.new" in args
  end

  test "stops at the first step that fails, with its exit code", %{tmp_dir: dir} do
    {3, stderr, [_only_one]} = init(["shop"], archives: dir, status: 3)
    assert stderr =~ "exited with 3"
  end

  test "refuses a name that is not an application name", %{tmp_dir: dir} do
    {1, stderr, []} = init(["My-Shop"], archives: dir)
    assert stderr =~ "not a valid application name"
  end

  test "refuses a directory that already exists", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      File.mkdir!("shop")
      {1, stderr, []} = init(["shop"], archives: dir)
      assert stderr =~ "already exists"
    end)
  end

  test "says how to get mise when it is missing", %{tmp_dir: dir} do
    {1, stderr, []} = init(["shop"], archives: dir, mise: nil)
    assert stderr =~ "brew install mise"
  end
end
