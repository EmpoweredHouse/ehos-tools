defmodule Mix.Tasks.EhosApp.InstallTest.CrashReports do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "crash reports" do
    # ehos-tools#234: what a crashed process held stays out of the report whoever reads the logs
    # reads.
    test "inspect a crashed process's state and last message as their shape alone" do
      assert get_in(read_config(installed(), :prod), [:logger, :translator_inspect_opts]) ==
               [limit: 0, printable_limit: 0]
    end

    test "put the filter first in start/2, before the tracing, once, with its module and test" do
      igniter =
        installed()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      application = content(igniter, "lib/test/application.ex")
      [before_tracing, _] = String.split(application, "OpentelemetryBandit.setup", parts: 2)

      assert before_tracing =~ "Test.LogRedaction.install()"
      assert length(String.split(application, "Test.LogRedaction.install()")) == 2
      assert content(igniter, "lib/test/log_redaction.ex") =~ "defmodule Test.LogRedaction do"

      assert content(igniter, "test/test/log_redaction_test.exs") =~
               "defmodule Test.LogRedactionTest do"
    end
  end
end
