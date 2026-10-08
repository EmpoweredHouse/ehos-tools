# The browser test (`:browser_test`) needs Playwright and its browser (`mix browser.setup`), so it runs
# only when included, as `mix check` includes it: then its page's script is bundled, its server
# started on a free port, and Playwright beside it.
# Included by its tag, with or without a value, or named as a file, with or without a line: a
# file's filter is set after this helper runs, so it is read from the command line.
browser_test? =
  Enum.any?(Keyword.get(ExUnit.configuration(), :include, []), fn
    :browser_test -> true
    {:browser_test, _value} -> true
    _other -> false
  end) or Enum.any?(System.argv(), &String.contains?(&1, "components_browser_test.exs"))

if browser_test? do
  0 = Esbuild.install_and_run(:browser, [])
  {:ok, _} = EhosDesign.Browser.Endpoint.start_link()
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  {:ok, {_ip, port}} = EhosDesign.Browser.Endpoint.server_info(:http)
  Application.put_env(:phoenix_test, :base_url, "http://127.0.0.1:#{port}")
end

ExUnit.start(exclude: [:browser_test])
