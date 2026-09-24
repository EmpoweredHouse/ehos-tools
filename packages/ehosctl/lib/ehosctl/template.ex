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

  # Igniter's install spec cannot name a subdirectory, so the installer must sit at the
  # root of the repository this points to. `EHOSCTL_TEMPLATE_SOURCE` overrides it, for
  # working on the template itself: `EHOSCTL_TEMPLATE_SOURCE=path:/abs/path/to/ehos_app`.
  # The path must be absolute: Igniter writes it into the new project's `mix.exs` as it
  # is, and Mix resolves a relative one from the new project, not from where ehosctl ran.
  @template_source "github:EmpoweredHouse/ehos_app@v0.1.0"

  @phx_new_args "--database postgres"

  def erlang, do: @erlang
  def elixir, do: @elixir
  def phx_new, do: @phx_new
  def igniter_new, do: @igniter_new
  def phx_new_args, do: @phx_new_args

  @doc "The `ehos_app` install spec, as `mix igniter.new --install` reads it."
  @spec install_spec() :: String.t()
  def install_spec do
    # An empty value is taken as unset: `ehos_app@` alone fails deep inside `igniter.new`.
    case System.get_env("EHOSCTL_TEMPLATE_SOURCE", "") do
      "" -> "ehos_app@" <> @template_source
      source -> "ehos_app@" <> source
    end
  end
end
