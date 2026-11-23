defmodule EhosApp.GeneratedProject.EventsQueueTest do
  # A project the template generated runs its contracts' effects through Oban's queue `:events`,
  # as configured, without `EhOsContract.Testing.drain/1`, which runs that queue itself and so
  # hid a project whose Oban ran only `:default` (#424). This runs against a real project, the
  # one `EHOS_APP_GENERATED_PROJECT` names, with its dependencies fetched and its development
  # database set up: CI's `e2e` job, after `ehosctl init shop` and `mix ecto.setup`. `mix check`
  # leaves it out (`test_helper.exs`). Locally, from a project the installer generated with the
  # example: `EHOS_APP_GENERATED_PROJECT=<its path> mix test --only generated_project`, with the
  # project's own server stopped, since the copy starts the application in `:dev` on its ports.
  use ExUnit.Case, async: false

  @moduletag :generated_project
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  # The example contract gets an effect delivered `:at_least_once`, the engine's default, which
  # tells the script's process that it ran. The project is copied, so that its contract stays
  # as the template wrote it.
  @effect """
    effect :note_entry, "Note a recorded entry",
      handles: :recorded,
      idempotency: [key: :event_id, owner: :self]
  end
  """

  test "an effect of a contract runs in the queue :events of the application, with no drain",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    copy = Path.join(dir, "project")
    {_, 0} = System.cmd("cp", ["-Rp", System.fetch_env!("EHOS_APP_GENERATED_PROJECT"), copy])

    [contract_file] = Path.wildcard(Path.join(copy, "lib/*/contracts/entries.ex"))
    source = File.read!(contract_file)
    [_, contract] = Regex.run(~r/^defmodule (\S+) do/, source)
    File.write!(contract_file, String.replace(source, ~r/^end\s*\z/m, @effect))

    File.write!(Path.join(Path.dirname(contract_file), "note_entry.ex"), """
    defmodule #{contract}.NoteEntry do
      @moduledoc false
      use #{contract}, effect: :note_entry

      @impl true
      def recorded(event) do
        send(:events_queue_test, {:effect_ran, event.entry_id})
        :ok
      end
    end
    """)

    script = Path.join(dir, "script.exs")

    File.write!(script, """
    Process.register(self(), :events_queue_test)
    entry = Ecto.UUID.generate()

    {:ok, _receipt} =
      EhOsContract.dispatch(#{contract}, %#{contract}.Commands.RecordEntry{entry_id: entry, amount: 10},
        actor: EhOsContract.Actor.system(:sample_data),
        idempotency_key: "events-queue:" <> entry
      )

    receive do
      {:effect_ran, ^entry} -> IO.puts("the effect ran")
    after
      60_000 -> IO.puts("the effect did not run in a minute")
    end
    """)

    {output, status} =
      System.cmd("mix", ["run", script],
        cd: copy,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}, {"EHOS_ISSUER", nil}, {"EHOS_AUDIENCE", nil}]
      )

    assert status == 0, output
    assert output =~ "the effect ran", output
  end
end
