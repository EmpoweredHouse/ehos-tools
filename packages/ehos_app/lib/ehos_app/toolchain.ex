defmodule EhosApp.Toolchain do
  @moduledoc """
  The Erlang and Elixir the installer is running under, as `.tool-versions` names them.

  `ehosctl init` runs the whole generation under the versions it pins, so the runtime
  that writes the file is the runtime the file records: the project, CI and the
  Dockerfile start from one pair instead of whatever the developer's machine had.
  """

  @doc """
  Returns `{:ok, [erlang: "28.5.0.7", elixir: "1.20.4-otp-28"]}` for the running VM.

  `otp_release` is only the major version. The full one, which precompiled builds are
  published under, is in the `OTP_VERSION` file of the installation at `otp_root`. When
  that file cannot be read, this returns `:error` rather than the major version alone:
  mise would take `erlang 28` as the newest 28.x, but asdf refuses it, and a pin one of
  them ignores is not a pin.
  """
  @spec current(Path.t()) :: {:ok, [erlang: String.t(), elixir: String.t()]} | :error
  def current(otp_root \\ to_string(:code.root_dir())) do
    otp_major = List.to_string(:erlang.system_info(:otp_release))

    case File.read(Path.join([otp_root, "releases", otp_major, "OTP_VERSION"])) do
      {:ok, version} ->
        {:ok, [erlang: String.trim(version), elixir: "#{System.version()}-otp-#{otp_major}"]}

      {:error, _} ->
        :error
    end
  end
end
