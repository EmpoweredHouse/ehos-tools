# The browser test (`:browser_test`) needs Playwright and its browser (`mix browser.setup`), so it runs
# only when included, as `mix check` includes it: then its page's script is bundled, its server
# started on a free port, and Playwright beside it.
if :browser_test in Keyword.get(ExUnit.configuration(), :include, []) do
  0 = Esbuild.install_and_run(:browser, [])
  {:ok, _} = EhosDesign.Browser.Endpoint.start_link()
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  {:ok, {_ip, port}} = EhosDesign.Browser.Endpoint.server_info(:http)
  Application.put_env(:phoenix_test, :base_url, "http://127.0.0.1:#{port}")
end

ExUnit.start(exclude: [:browser_test])
