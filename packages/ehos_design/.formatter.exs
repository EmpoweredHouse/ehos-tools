# Used by "mix format"
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # Not the repository's test support, which the other packages format: Phoenix's rules here
  # would format it apart from them (ehos-tools#690).
  inputs: ["*.{heex,ex,exs}", "{mix,.formatter}.exs", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
