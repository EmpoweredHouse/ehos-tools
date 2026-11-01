defmodule Mix.Tasks.EhosApp.InstallTest.CrashReports do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "crash reports" do
    # ehos-tools#234: what a crashed process held stays out of the report whoever reads the logs
    # reads.
    @tag :tmp_dir
    test "inspect a crashed process's state and last message as their shape alone", %{
      tmp_dir: tmp_dir
    } do
      assert get_in(read_config(installed(), :prod, tmp_dir), [:logger, :translator_inspect_opts]) ==
               [limit: 0, printable_limit: 0]
    end

    test "put the filter first in start/2, before the tracing, once, with its module and test" do
      igniter =
        installed()
        |> Igniter.compose_task("ehos_app.install", [])
        |> apply_igniter!()

      application = content(igniter, "lib/test/application.ex")

      assert lines(
               application,
               "  def start(_type, _args) do",
               "    OpentelemetryBandit.setup(public_endpoint: true)"
             ) == """
               def start(_type, _args) do
                 # Test.LogRedaction: a crashed process's report keeps out what it held.
                 Test.LogRedaction.install()
                 # eh-os D-93: a trace of each request and query, sent where EHOS says, if it says.
                 OpentelemetryBandit.setup(public_endpoint: true)
             """

      assert lines_starting(application, "    Test.LogRedaction.") == [
               "    Test.LogRedaction.install()"
             ]

      assert lines_starting(content(igniter, "lib/test/log_redaction.ex"), "defmodule ") == [
               "defmodule Test.LogRedaction do"
             ]

      assert lines_starting(content(igniter, "test/test/log_redaction_test.exs"), "defmodule ") ==
               ["defmodule Test.LogRedactionTest do"]
    end
  end
end
