# Configuration for this package's own tests only: a host that depends on the package never
# reads it. The browser test (test/browser) serves one page and drives it with Playwright.
import Config

config :phoenix, :json_library, JSON

if config_env() == :test do
  config :ehos_design, EhosDesign.Browser.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    url: [host: "127.0.0.1", port: 4087],
    http: [ip: {127, 0, 0, 1}, port: 4087],
    server: true,
    secret_key_base: String.duplicate("browser-test-only-", 4),
    live_view: [signing_salt: "browser-test"],
    render_errors: [formats: [html: EhosDesign.Browser.Layout], layout: false]

  config :phoenix_test,
    otp_app: :ehos_design,
    endpoint: EhosDesign.Browser.Endpoint,
    playwright: [assets_dir: Path.expand("../test/browser", __DIR__)]

  # The page's script, bundled from test/browser/app.js with LiveView's client from deps and
  # the colocated hook's manifest from the build, as a host's esbuild bundles its own.
  config :esbuild,
    version: "0.25.4",
    browser: [
      args:
        ~w(app.js --bundle --target=es2022 --outdir=#{Path.expand("../_build/test/browser", __DIR__)}),
      cd: Path.expand("../test/browser", __DIR__),
      env: %{
        "NODE_PATH" => [Path.expand("../deps", __DIR__), Path.expand("../_build/test", __DIR__)]
      }
    ]

  config :logger, level: :warning
end
