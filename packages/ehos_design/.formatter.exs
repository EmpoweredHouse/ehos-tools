# Used by "mix format"
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{mix,.formatter}.exs", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
