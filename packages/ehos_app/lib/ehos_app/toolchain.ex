defmodule EhosApp.Toolchain do
  @moduledoc """
  The Erlang and Elixir the installer is running under, as `.tool-versions` names them.

  `ehosctl init` runs the whole generation under the versions it pins, so the runtime
  that writes the file is the runtime the file records: the project, CI and the
  Dockerfile start from one pair instead of whatever the developer's machine had.
  """

  @doc "Returns `[erlang: \"28.5.0.7\", elixir: \"1.20.4-otp-28\"]` for the running VM."
  @spec current() :: [erlang: String.t(), elixir: String.t()]
  def current do
    otp_major = List.to_string(:erlang.system_info(:otp_release))
    [erlang: otp_version(otp_major), elixir: "#{System.version()}-otp-#{otp_major}"]
  end

  # `otp_release` is only the major version. The full one, which precompiled builds
  # are published under, is in the OTP_VERSION file of the running installation.
  defp otp_version(otp_major) do
    path = Path.join([:code.root_dir(), "releases", otp_major, "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      {:error, _} -> otp_major
    end
  end
end
