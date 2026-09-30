defmodule Ehosctl.Template do
  @moduledoc """
  Everything `ehosctl init` generates from, pinned into the binary.

  One `ehosctl` release means one template: the same toolchain, the same Phoenix
  generator and the same `ehos_app` installer, whichever machine runs it and whenever.
  Changing any of these is a new release of `ehosctl`, the way a new `phx_new` archive
  is a new Phoenix template.
  """

  @erlang "28.5.0.7"
  @elixir "1.20.4-otp-28"
  @phx_new "1.8.14"
  @igniter_new "0.5.34"

  # `ehos_app` lives in a subdirectory of ehos-tools, and Igniter's install spec
  # (`mix igniter.install ehos_app@github:…`) has no `sparse:`. So `init` installs it
  # through `Igniter.Util.Install.install/2`, which takes a dependency as Mix does, and
  # composes the installers it declares (Oban's) as `igniter.install` would. The tag is
  # one of ehos-tools' own, made for each release of the template.
  @template_tag "ehos_app-v0.2.0"
  @template_repo "EmpoweredHouse/ehos-tools"

  @phx_new_args "--database postgres"

  def erlang, do: @erlang
  def elixir, do: @elixir
  def phx_new, do: @phx_new
  def igniter_new, do: @igniter_new
  def phx_new_args, do: @phx_new_args

  @doc """
  The `ehos_app` dependency `init` installs: the pinned tag of ehos-tools, or what
  `EHOSCTL_TEMPLATE_SOURCE` names, for working on the template.

    * `path:<absolute path>` - a local checkout of `packages/ehos_app`. The path is
      written into the new project's `mix.exs` as it is, and Mix resolves a relative one
      from the new project, so it must be absolute, and such a project is for trying
      the template, not for keeping.
    * `ref:<git ref>` - another commit, branch or tag of ehos-tools.
  """
  @spec install_dep() :: {:ok, {:ehos_app, keyword()}} | {:error, String.t()}
  def install_dep do
    # An empty value is taken as unset, as a shell's `VAR= ehosctl init` means.
    case System.get_env("EHOSCTL_TEMPLATE_SOURCE", "") do
      "" -> {:ok, github(tag: @template_tag)}
      "ref:" <> ref when ref != "" -> {:ok, github(ref: ref)}
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
  @spec install_expression({:ehos_app, keyword()}) :: String.t()
  def install_expression(dep) do
    "{:ok, _} = Application.ensure_all_started(:rewrite); " <>
      "Igniter.Util.Install.install([#{inspect(dep)}], [\"--example\", \"--yes\"])"
  end

  defp github(ref), do: {:ehos_app, [github: @template_repo, sparse: "packages/ehos_app"] ++ ref}
end
