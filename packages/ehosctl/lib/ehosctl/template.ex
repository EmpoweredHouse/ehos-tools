defmodule Ehosctl.Template do
  @moduledoc """
  Everything `ehosctl init` generates from, pinned into the binary.

  One `ehosctl` release means one template: the same toolchain, the same Phoenix
  generator and the same `ehos_app` installer, whichever machine runs it and whenever.
  Changing any of these is a new release of `ehosctl`, the way a new `phx_new` archive
  is a new Phoenix template. The contract engine is pinned too: `ehos_app` pins
  ehos_contract's release by the commit its tag names (T-11).
  """

  @erlang "28.5.0.7"
  @elixir "1.20.4-otp-28"
  @phx_new "1.8.14"
  @igniter_new "0.5.34"
  # `igniter.new` gives the new project `{:igniter, "~> 0.6", only: [:dev, :test]}`, so its lock
  # takes the newest Igniter. `ehos_app` and `oidcc` require Igniter below 0.9, which came out on
  # 27 November 2026, so `init` narrows the requirement to this one before it installs `ehos_app`.
  # `ehos_app` cannot simply allow 0.9: it adds a supervision tree's children in another order.
  # When `ehos_app` moves to a later Igniter, this moves in the same change.
  @igniter "~> 0.8.6"

  # `ehos_app` lives in a subdirectory of ehos-tools, and Igniter's install spec
  # (`mix igniter.install ehos_app@github:…`) has no `sparse:`. So `init` installs it
  # through `Igniter.Util.Install.install/2`, which takes a dependency as Mix does, and
  # composes the installers it declares (Oban's) as `igniter.install` would. Pinned to the
  # commit ehos-tools' tag `ehos_app-v0.39.0` names, not to the tag, which nothing stops
  # being moved: this is the code the new project runs as its installer (T-02). Find the
  # commit of a release with `git rev-parse ehos_app-vX.Y.Z^{commit}`. The version that
  # release has in its `mix.exs` goes beside it, and `Ehosctl.TemplateTest` checks the two
  # agree. Mix checks a git dependency's version when the project compiles, not when it is
  # fetched, and `init` runs the installer without that check, so a commit of another release
  # copied here by mistake would run, and the project's first compile would refuse it; a
  # later commit of the same version is not caught at all.
  @template_ref "cf885ec8e13bd2d6145ae7f8bf0c4ee6fa928c6c"
  @template_version "0.39.0"
  # The ehos_contract release that `ehos_app` @template_version pins (T-11), said by `--version`;
  # `Ehosctl.TemplateTest` holds it to that commit's installer.
  @ehos_contract_version "0.17.0"
  @template_repo "EmpoweredHouse/ehos-tools"

  @phx_new_args "--database postgres"

  @doc """
  The version of `ehos_app` a new project is created from: the one its `mix.exs` has at the
  pinned commit, which `install_dep/0` requires.
  """
  @spec template_version() :: String.t()
  def template_version, do: @template_version

  @doc "The ehos_contract release the pinned `ehos_app` pins in a new project (T-11)."
  @spec ehos_contract_version() :: String.t()
  def ehos_contract_version, do: @ehos_contract_version

  @doc "The Erlang/OTP version a new project is generated under and pinned to."
  @spec erlang() :: String.t()
  def erlang, do: @erlang

  @doc "The Elixir version a new project is generated under and pinned to."
  @spec elixir() :: String.t()
  def elixir, do: @elixir

  @doc "The version of the `phx_new` archive that generates the Phoenix project."
  @spec phx_new() :: String.t()
  def phx_new, do: @phx_new

  @doc "The version of the `igniter_new` archive that runs `mix igniter.new`."
  @spec igniter_new() :: String.t()
  def igniter_new, do: @igniter_new

  @doc "The requirement on Igniter that `init` gives the new project."
  @spec igniter() :: String.t()
  def igniter, do: @igniter

  @doc """
  The Elixir `init` runs in the new project, with `elixir -e`, to narrow the requirement on
  Igniter that `igniter.new` wrote to `igniter/0`'s. It raises when `mix.exs` has no such
  requirement, so a later `igniter_new` that writes another one fails `init` here.
  """
  @spec igniter_expression() :: String.t()
  def igniter_expression do
    # As `igniter.new` writes it (`Mix.Tasks.Igniter.New.add_igniter_dep/2`).
    from = ~s({:igniter, "~> 0.6", only: [:dev, :test]})
    to = ~s({:igniter, "#{@igniter}", only: [:dev, :test]})

    "contents = File.read!(\"mix.exs\"); " <>
      "String.contains?(contents, #{inspect(from)}) || " <>
      "raise(\"mix.exs has no \" <> #{inspect(from)}); " <>
      "File.write!(\"mix.exs\", String.replace(contents, #{inspect(from)}, #{inspect(to)}))"
  end

  @doc "The arguments `init` hands `phx.new`, as one string for `mix igniter.new --with-args`."
  @spec phx_new_args() :: String.t()
  def phx_new_args, do: @phx_new_args

  @doc """
  What `init` creates an application from, as a label and a value each, for `ehosctl --version`:
  the template and the toolchain this release pins, and the contract engine's release, which the
  template pins (T-11).
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
      {"igniter", @igniter},
      {"ehos_contract", "#{@ehos_contract_version}, which ehos_app #{@template_version} pins"}
    ]
  end

  @doc """
  What `EHOSCTL_TEMPLATE_SOURCE` holds in place of the pinned `ehos_app`, or `nil` when it is
  unset or empty.
  """
  @spec source_override() :: String.t() | nil
  def source_override do
    # An empty value is taken as unset, as a shell's `VAR= ehosctl init` means.
    case Ehosctl.SystemEnv.current().get("EHOSCTL_TEMPLATE_SOURCE") do
      blank when blank in [nil, ""] -> nil
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
      nil ->
        {:ok, {:ehos_app, "== #{@template_version}", github_opts(ref: @template_ref)}}

      "ref:" <> ref when ref != "" ->
        {:ok, {:ehos_app, github_opts(ref: ref)}}

      "path:/" <> _ = "path:" <> path ->
        {:ok, {:ehos_app, path: path, override: true}}

      other ->
        {:error,
         "EHOSCTL_TEMPLATE_SOURCE is #{inspect(other)}, and ehosctl does not accept it. " <>
           source_usage() <> "."}
    end
  end

  @doc "What `EHOSCTL_TEMPLATE_SOURCE` takes."
  @spec source_usage() :: String.t()
  def source_usage do
    "Give path:PATH, with the absolute path of packages/ehos_app, or ref:REF, with a git ref " <>
      "of #{@template_repo}"
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
