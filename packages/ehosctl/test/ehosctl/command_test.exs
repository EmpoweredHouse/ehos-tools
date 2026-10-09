defmodule Ehosctl.CommandTest do
  use ExUnit.Case, async: true

  # eh-os D-87's confirmation: every command belongs to one plane. A new command fails here
  # until it is added with its plane, so the plane is a choice made in review, not a default.
  @planes %{init: :local}

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
