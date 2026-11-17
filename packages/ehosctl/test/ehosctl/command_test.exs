defmodule Ehosctl.CommandTest do
  use Ehosctl.Case, async: true

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
    db: :governed,
    people: :governed,
    mail: :governed,
    services: :governed,
    deploy: :governed,
    promotions: :governed,
    promote: :governed,
    approve: :governed,
    refuse: :governed,
    builds: :governed,
    landscape: :governed,
    graph: :governed,
    env: :governed,
    resources: :governed,
    "role-bindings": :governed,
    trusts: :governed,
    secrets: :governed,
    github: :governed,
    logs: :governed,
    audit: :governed,
    activity: :governed,
    agents: :governed,
    status: :governed,
    domains: :governed,
    verify: :governed,
    doctor: :platform,
    server: :platform,
    install: :platform,
    upgrade: :platform,
    versions: :governed,
    changelog: :governed
  }

  # Where `ehosctl --help` lists each command. A new command fails here until it is listed with
  # its group, so the place a newcomer finds it is chosen in review.
  @groups %{
    init: :start,
    verify: :start,
    login: :sign_in,
    logout: :sign_in,
    whoami: :sign_in,
    terminals: :sign_in,
    installations: :sign_in,
    credential: :sign_in,
    apps: :applications,
    builds: :applications,
    deploy: :applications,
    promotions: :applications,
    promote: :applications,
    approve: :applications,
    refuse: :applications,
    call: :applications,
    logs: :applications,
    secrets: :applications,
    db: :applications,
    domains: :applications,
    mail: :applications,
    services: :applications,
    env: :applications,
    resources: :applications,
    landscape: :applications,
    graph: :applications,
    people: :access,
    agents: :access,
    roles: :access,
    "role-bindings": :access,
    trusts: :access,
    github: :access,
    audit: :access,
    activity: :access,
    status: :installation,
    versions: :installation,
    changelog: :installation,
    doctor: :installation,
    server: :installation,
    install: :installation,
    upgrade: :installation
  }

  # The width of a terminal that nobody has widened: each command's line of `ehosctl --help` fits
  # in it, so the list stays one line for each command.
  @columns 80

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

  test "lists every command with its group" do
    assert Map.new(Ehosctl.CLI.commands(), &{&1.name(), &1.group()}) == @groups
  end

  test "every command's group is one that ehosctl --help lists" do
    groups = Keyword.keys(Ehosctl.Command.groups())
    assert Enum.reject(Ehosctl.CLI.commands(), &(&1.group() in groups)) == []
  end

  test "every command's summary is one sentence" do
    assert Enum.reject(Ehosctl.CLI.commands(), &(&1.summary() =~ ~r/\A[A-Z][^.]*\.\z/)) == []
  end

  test "every line of ehosctl --help fits in a terminal nobody has widened" do
    help = capture_io(fn -> assert Ehosctl.CLI.main(["--help"]) == 0 end)

    assert Enum.reject(String.split(help, "\n"), &(String.length(&1) <= @columns)) == []
  end

  # The planes are eh-os D-87's.
  test "every command's plane is governed, platform or local" do
    assert Enum.reject(Ehosctl.CLI.commands(), &(&1.plane() in Ehosctl.Command.planes())) == []
  end

  # A sign-in acts as the person, so only the governed plane may reach it (eh-os D-87, T-08):
  # the token store, the credentials it renews, and the protocol that obtains them.
  @sign_in_files ~w(lib/ehosctl/token_store.ex lib/ehosctl/token_store/ lib/ehosctl/credentials.ex
                    lib/ehosctl/sign_in.ex lib/ehosctl/sign_in/)

  test "no command outside the governed plane reaches the token store" do
    reaching =
      for command <- Ehosctl.CLI.commands(), command.plane() != :governed do
        source = Path.relative_to_cwd(to_string(command.module_info(:compile)[:source]))

        # Every file the command's file refers to, directly or through others; xref's own
        # output, so only the file it starts from can be known.
        reached = capture_io(fn -> Mix.Task.rerun("xref", ["graph", "--source", source]) end)
        assert reached =~ source

        {command, Enum.filter(@sign_in_files, &(reached =~ &1))}
      end

    assert Enum.reject(reaching, &match?({_command, []}, &1)) == []
  end

  test "no governed command calls a tool of the platform plane" do
    calling =
      for command <- Ehosctl.CLI.commands(),
          command.plane() == :governed,
          source <- [command.module_info(:compile)[:source] |> to_string() |> File.read!()],
          tool <- @platform_tools,
          source =~ ~r/["'`]#{tool}\b/,
          do: {command, tool}

    assert calling == []
  end
end
