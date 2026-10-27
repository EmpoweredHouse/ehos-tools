defmodule Ehosctl.CommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # eh-os D-87's confirmation: every command belongs to one plane. A new command fails here
  # until it is added with its plane, so the plane is a choice made in review, not a default.
  @planes %{
    init: :local,
    installations: :local,
    login: :governed,
    logout: :governed,
    whoami: :governed,
    terminals: :governed,
    roles: :governed,
    apps: :governed,
    credential: :governed,
    call: :governed,
    people: :governed,
    mail: :governed,
    deploy: :governed,
    builds: :governed,
    landscape: :governed,
    graph: :governed,
    env: :governed,
    resources: :governed,
    "role-bindings": :governed,
    trust: :governed,
    secret: :governed,
    github: :governed,
    logs: :governed,
    audit: :governed,
    activity: :governed,
    agents: :governed,
    installation: :governed,
    verify: :governed,
    doctor: :platform,
    server: :platform,
    install: :platform,
    upgrade: :platform,
    versions: :governed,
    changelog: :governed
  }

  # A governed command acts only with what EHOS issued. These tools act with accounts EHOS
  # does not issue, so a governed command that calls one is a way around EHOS (eh-os D-87).
  @platform_tools ~w(kubectl helm tofu ssh)

  test "lists every command with its plane" do
    assert Map.new(Ehosctl.CLI.commands(), &{&1.name(), &1.plane()}) == @planes
  end

  test "every module that implements a command is on the command line" do
    {:ok, modules} = :application.get_key(:ehosctl, :modules)

    implementing =
      Enum.filter(modules, fn module ->
        Ehosctl.Command in List.flatten(
          Keyword.get_values(module.module_info(:attributes), :behaviour)
        )
      end)

    assert Enum.sort(implementing) == Enum.sort(Ehosctl.CLI.commands())
  end

  test "every command's plane is one of D-87's" do
    for command <- Ehosctl.CLI.commands() do
      assert command.plane() in Ehosctl.Command.planes(), "#{inspect(command)}"
    end
  end

  # A sign-in acts as the person, so only the governed plane may reach it (eh-os D-87, T-08):
  # the token store, the credentials it renews, and the protocol that obtains them.
  @sign_in_files ~w(lib/ehosctl/token_store.ex lib/ehosctl/token_store/ lib/ehosctl/credentials.ex
                    lib/ehosctl/sign_in.ex lib/ehosctl/sign_in/)

  test "no command outside the governed plane reaches the token store" do
    for command <- Ehosctl.CLI.commands(), command.plane() != :governed do
      source = Path.relative_to_cwd(to_string(command.module_info(:compile)[:source]))

      # Every file the command's file refers to, directly or through others.
      reached = capture_io(fn -> Mix.Task.rerun("xref", ["graph", "--source", source]) end)
      assert reached =~ source

      for file <- @sign_in_files do
        refute reached =~ file, "#{inspect(command)} is #{command.plane()} and reaches #{file}"
      end
    end
  end

  test "no governed command calls a tool of the platform plane" do
    for command <- Ehosctl.CLI.commands(), command.plane() == :governed do
      source = command.module_info(:compile)[:source] |> to_string() |> File.read!()

      for tool <- @platform_tools do
        refute source =~ ~r/["'`]#{tool}\b/,
               "#{inspect(command)} is governed and names #{tool}"
      end
    end
  end
end
