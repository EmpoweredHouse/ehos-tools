# The browser test's page: its script bundled, its server started, and Playwright beside it.
0 = Esbuild.install_and_run(:browser, [])
{:ok, _} = EhosDesign.Browser.Endpoint.start_link()
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
Application.put_env(:phoenix_test, :base_url, EhosDesign.Browser.Endpoint.url())

ExUnit.start()
