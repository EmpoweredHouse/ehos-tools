# Used by "mix format"
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    # The repository's test support, compiled into this package's tests (ehos-tools#690).
    "../../test/support/**/*.{ex,exs}"
  ]
]
