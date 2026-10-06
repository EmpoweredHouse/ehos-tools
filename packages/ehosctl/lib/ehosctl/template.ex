defmodule Ehosctl.Template do
  @moduledoc """
  Everything `ehosctl init` generates from, pinned into the binary.

  One `ehosctl` release means one template: the same toolchain, the same Phoenix
  generator and the same `ehos_app` installer, whichever machine runs it and whenever.
  Changing any of these is a new release of `ehosctl`, the way a new `phx_new` archive
  is a new Phoenix template. The one exception is the contract engine, which `ehos_app`
  takes from eh-os-contract's `main` while eh-os-contract tags no release (T-05), so the
  new project's `mix.lock` holds the commit of the day it was generated.
  """

  @erlang "28.5.0.7"
  @elixir "1.20.4-otp-28"
  @phx_new "1.8.14"
  @igniter_new "0.5.34"

  # `ehos_app` lives in a subdirectory of ehos-tools, and Igniter's install spec
  # (`mix igniter.install ehos_app@github:…`) has no `sparse:`. So `init` installs it
  # through `Igniter.Util.Install.install/2`, which takes a dependency as Mix does, and
  # composes the installers it declares (Oban's) as `igniter.install` would. Pinned to the
  # commit ehos-tools' tag `ehos_app-v0.5.0` names, not to the tag, which nothing stops
  # being moved: this is the code the new project runs as its installer (T-02). Find the
  # commit of a release with `git rev-parse ehos_app-vX.Y.Z^{commit}`. The version that
  # release has in its `mix.exs` goes beside it, and `Ehosctl.TemplateTest` checks the two
  # agree. Mix checks a git dependency's version when the project compiles, not when it is
  # fetched, and `init` runs the installer without that check, so a commit of another release
  # copied here by mistake would run, and the project's first compile would refuse it; a
  # later commit of the same version is not caught at all.
  @template_ref "9f3cfd231f79519a33ff19f26ca26d13d11599b2"
  @template_version "0.5.0"
  @template_repo "EmpoweredHouse/ehos-tools"

  @phx_new_args "--database postgres"

  def erlang, do: @erlang
  def elixir, do: @elixir
  def phx_new, do: @phx_new
  def igniter_new, do: @igniter_new
  def phx_new_args, do: @phx_new_args

  @doc """
  What `init` creates an application from, as a label and a value each, for `ehosctl --help`:
  the template and the toolchain this release pins, and the contract engine, which it does not
  (T-05).
  """
  @spec pins() :: [{String.t(), String.t()}]
  def pins do
    [
      {"ehos_app",
       "#{@template_version} (#{@template_repo} at #{String.slice(@template_ref, 0, 7)})"},
      {"Erlang", @erlang},
      {"Elixir", @elixir},
      {"phx_new", @phx_new},
      {"igniter_new", @igniter_new},
      {"eh_os_contract", "eh-os-contract's main, at its latest commit when init runs"}
    ]
  end

  @doc """
  What `EHOSCTL_TEMPLATE_SOURCE` holds in place of the pinned `ehos_app`, or `nil` when it is
  unset or empty.
  """
  @spec source_override() :: String.t() | nil
  def source_override do
    # An empty value is taken as unset, as a shell's `VAR= ehosctl init` means.
    case System.get_env("EHOSCTL_TEMPLATE_SOURCE", "") do
      "" -> nil
      source -> source
    end
  end

  @doc """
  The `ehos_app` dependency `init` installs: the pinned commit of ehos-tools, or what
  `EHOSCTL_TEMPLATE_SOURCE` names, for working on the template.

    * `path:<absolute path>` - a local checkout of `packages/ehos_app`. The path is
      written into the new project's `mix.exs` as it is, and Mix resolves a relative one
      from the new project, so it must be absolute, and such a project is for trying
      the template, not for keeping.
    * `ref:<git ref>` - another commit, branch or tag of ehos-tools.
  """
  @spec install_dep() ::
          {:ok, {:ehos_app, keyword()} | {:ehos_app, String.t(), keyword()}}
          | {:error, String.t()}
  def install_dep do
    case source_override() do
      nil -> {:ok, {:ehos_app, "== #{@template_version}", github_opts(ref: @template_ref)}}
      "ref:" <> ref when ref != "" -> {:ok, {:ehos_app, github_opts(ref: ref)}}
      "path:/" <> _ = "path:" <> path -> {:ok, {:ehos_app, path: path, override: true}}
      other -> {:error, "EHOSCTL_TEMPLATE_SOURCE is #{inspect(other)}; " <> source_usage()}
    end
  end

  @doc "What `EHOSCTL_TEMPLATE_SOURCE` takes."
  @spec source_usage() :: String.t()
  def source_usage do
    "it takes path:<absolute path to packages/ehos_app> or ref:<a git ref of #{@template_repo}>"
  end

  @doc """
  The Elixir `init` runs in the new project, with `mix run --no-start`, to install `dep`
  and run its installer with `--example`. `mix run --no-start` starts no application,
  and Igniter's own Mix tasks start `:rewrite` before they use it.
  """
  @spec install_expression({:ehos_app, keyword()} | {:ehos_app, String.t(), keyword()}) ::
          String.t()
  def install_expression(dep) do
    "{:ok, _} = Application.ensure_all_started(:rewrite); " <>
      "Igniter.Util.Install.install([#{inspect(dep)}], [\"--example\", \"--yes\"])"
  end

  defp github_opts(ref), do: [github: @template_repo, sparse: "packages/ehos_app"] ++ ref
end
