# Draft, not yet tested. It belongs in EmpoweredHouse/homebrew-tap (Homebrew requires the
# `homebrew-` prefix), rendered by the release workflow with the real version and checksums:
#
#   brew install empoweredhouse/tap/ehosctl
#
# Prebuilt binaries are allowed in a tap, not in homebrew-core. mise is a dependency
# because `ehosctl init` runs everything under the Erlang and Elixir it pins, through mise.
class Ehosctl < Formula
  desc "Command-line tool for EHOS"
  homepage "https://github.com/empoweredhouse/ehos-tools"
  version "0.1.0"
  # No `license` until one is selected: see the README.

  depends_on "mise"

  base = "https://github.com/empoweredhouse/ehos-tools/releases/download/v#{version}"

  on_macos do
    on_arm do
      url "#{base}/ehosctl_macos_arm64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "#{base}/ehosctl_macos_x64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "#{base}/ehosctl_linux_arm64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "#{base}/ehosctl_linux_x64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    bin.install Dir["ehosctl_*"].first => "ehosctl"
  end

  test do
    assert_match "ehosctl #{version}", shell_output("#{bin}/ehosctl --version")
  end
end
