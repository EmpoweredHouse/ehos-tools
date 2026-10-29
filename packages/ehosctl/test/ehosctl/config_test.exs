defmodule Ehosctl.ConfigTest do
  use Ehosctl.Case, async: true

  import Bitwise

  alias Ehosctl.Config

  doctest Ehosctl.Config

  @moduletag :tmp_dir

  # The file `config/0` is written as.
  @written %{
    "version" => 1,
    "current" => "local",
    "installations" => %{
      "local" => %{"url" => "http://ehos.localhost"},
      "staging" => %{"url" => "https://ehos.staging.example.com"}
    }
  }

  @shared_ca "holds a CA ehosctl would trust, and others than you can change it; make it, " <>
               "and the directory it is in, yours and writable by no one else"

  test "is looked for in EHOSCTL_CONFIG_DIR, then XDG_CONFIG_HOME, then ~/.config" do
    assert Config.dir(%{"EHOSCTL_CONFIG_DIR" => "/e", "XDG_CONFIG_HOME" => "/x"}) == "/e"
    assert Config.dir(%{"EHOSCTL_CONFIG_DIR" => "", "XDG_CONFIG_HOME" => "/x"}) == "/x/ehosctl"

    stub_home("/home/someone")
    assert Config.dir(%{"XDG_CONFIG_HOME" => ""}) == "/home/someone/.config/ehosctl"
  end

  test "a directory without a configuration holds no installations", %{tmp_dir: dir} do
    assert Config.read(Path.join(dir, "none")) == {:ok, %Config{}}
  end

  test "writes the documented shape, and reads back what it wrote", %{tmp_dir: dir} do
    dir = Path.join(dir, "ehosctl")
    assert Config.write(config(), dir) == :ok

    assert dir |> Config.path() |> File.read!() |> JSON.decode!() == @written
    assert Config.read(dir) == {:ok, config()}
  end

  test "keeps the file readable only by the user, in a directory only they can open",
       %{tmp_dir: dir} do
    dir = Path.join(dir, "ehosctl")
    :ok = Config.write(config(), dir)

    assert (File.stat!(dir).mode &&& 0o777) == 0o700
    assert (File.stat!(Config.path(dir)).mode &&& 0o777) == 0o600
    assert File.ls!(dir) == ["config.json"]
  end

  test "leaves a directory it did not create as it was", %{tmp_dir: dir} do
    File.chmod!(dir, 0o755)
    :ok = Config.write(config(), dir)
    assert (File.stat!(dir).mode &&& 0o777) == 0o755
    assert (File.stat!(Config.path(dir)).mode &&& 0o777) == 0o600
  end

  test "rewrites the file a symbolic link points to, and keeps the link", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "dotfiles"))
    File.write!(Path.join(dir, "dotfiles/ehosctl.json"), "")
    File.mkdir_p!(Path.join(dir, "config"))
    File.ln_s!("../dotfiles/ehosctl.json", Config.path(Path.join(dir, "config")))

    :ok = Config.write(config(), Path.join(dir, "config"))

    assert File.read_link(Config.path(Path.join(dir, "config"))) ==
             {:ok, "../dotfiles/ehosctl.json"}

    assert Config.read(Path.join(dir, "config")) == {:ok, config()}
    assert File.ls!(Path.join(dir, "dotfiles")) == ["ehosctl.json"]
  end

  test "writes the file it reads when a linked directory leads to a relative link",
       %{tmp_dir: dir} do
    # ~/.config links to ~/sync/config, and config.json to ../../dotfiles/ehosctl.json: the
    # kernel resolves `..` from sync/config/ehosctl, where the link is.
    File.mkdir_p!(Path.join(dir, "sync/config/ehosctl"))
    File.mkdir_p!(Path.join(dir, "sync/dotfiles"))
    File.write!(Path.join(dir, "sync/dotfiles/ehosctl.json"), "")
    File.ln_s!(Path.join(dir, "sync/config"), Path.join(dir, "config"))
    config_dir = Path.join(dir, "config/ehosctl")
    File.ln_s!("../../dotfiles/ehosctl.json", Config.path(config_dir))

    :ok = Config.write(config(), config_dir)

    assert Config.read(config_dir) == {:ok, config()}

    assert dir |> Path.join("sync/dotfiles/ehosctl.json") |> File.read!() |> JSON.decode!() ==
             @written
  end

  test "refuses a directory others can write to, where they could plant a link",
       %{tmp_dir: dir} do
    File.chmod!(dir, 0o777)

    assert Config.write(config(), dir) ==
             {:error, :failed,
              "#{dir} can be written by others; ehosctl does not keep its configuration there"}

    refute File.exists?(Config.path(dir))
  end

  test "carries what a later ehosctl keeps beside an installation's URL", %{tmp_dir: dir} do
    File.write!(
      Config.path(dir),
      ~s({"version":1,"current":null,"installations":{"a":{"url":"u","signed_in_as":"x"}}})
    )

    {:ok, config} = Config.read(dir)
    :ok = Config.write(config, dir)

    assert Config.read(dir) ==
             {:ok,
              %Config{
                current: nil,
                installations: %{"a" => %{"url" => "u", "signed_in_as" => "x"}}
              }}
  end

  test "refuses a file a newer ehosctl wrote, and leaves it as it was", %{tmp_dir: dir} do
    newer = ~s({"version":2,"installations":{}})
    File.write!(Config.path(dir), newer)

    assert Config.read(dir) ==
             {:error, :failed,
              "#{Config.path(dir)} was written by a newer ehosctl (version 2); " <>
                "upgrade ehosctl to use it"}

    assert File.read!(Config.path(dir)) == newer
  end

  test "refuses a file that is not a configuration, saying which file", %{tmp_dir: dir} do
    not_json = "#{Config.path(dir)} is not JSON; fix or remove it"
    not_a_configuration = "#{Config.path(dir)} is not an ehosctl configuration; fix or remove it"

    for {contents, message} <- [
          {"{not json", not_json},
          {~s({"version":1}), not_a_configuration},
          {~s({"version":1,"installations":{"Bad Name":{}}}), not_a_configuration},
          {~s({"version":1,"current":"gone","installations":{}}), not_a_configuration},
          {~s({"version":1,"installations":{"a":{}}}), not_a_configuration},
          {~s({"version":1,"installations":{"a":{"url":27}}}), not_a_configuration},
          {~s({"version":1,"installations":{"a":{"url":null}}}), not_a_configuration},
          {~s({"version":1,"installations":{"a":{"url":"u","ca":27}}}), not_a_configuration},
          {JSON.encode!(%{
             "version" => 1,
             "installations" => %{
               "a" => %{"url" => "u", "ca" => String.duplicate("-", 1_048_577)}
             }
           }), not_a_configuration},
          {~s({"version":1,"installations":{"a":{"url":"x\\u001b]0;pwned\\u0007y"}}}),
           not_a_configuration},
          {~s({"version":1,"installations":{"a":{"url":"https://example.com/\\u202Egnp.exe"}}}),
           not_a_configuration}
        ] do
      File.write!(Config.path(dir), contents)
      assert Config.read(dir) == {:error, :failed, message}
    end
  end

  test "keeps a CA beside an installation, and drops it with its sign-in when the URL changes",
       %{tmp_dir: dir} do
    config = config() |> Config.put_ca("staging", "pem") |> Config.put_sign_in("staging", %{})
    :ok = Config.write(config, dir)
    assert Config.read(dir) == {:ok, config}

    assert Config.put(config, "staging", "https://ehos.staging.example.com") == config
    assert Config.ca({"staging", config.installations["staging"]}) == {"staging", "pem"}

    moved = Config.put(config, "staging", "https://ehos.elsewhere.example.com")

    assert moved == %Config{
             current: "local",
             installations: %{
               "local" => %{"url" => "http://ehos.localhost"},
               "staging" => %{"url" => "https://ehos.elsewhere.example.com"}
             }
           }

    assert Config.ca({"staging", moved.installations["staging"]}) == nil

    assert Config.put_ca(config, "staging", nil) == %Config{
             current: "local",
             installations: %{
               "local" => %{"url" => "http://ehos.localhost"},
               "staging" => %{"url" => "https://ehos.staging.example.com", "sign_in" => %{}}
             }
           }
  end

  test "trusts no CA kept in a file, or a directory, others can change", %{tmp_dir: dir} do
    config = Config.put_ca(config(), "staging", "pem")
    :ok = Config.write(config, dir)
    assert Config.read(dir) == {:ok, config}

    for {path, mode} <- [{Config.path(dir), 0o620}, {dir, 0o777}] do
      File.chmod!(path, mode)
      assert Config.read(dir) == {:error, :failed, "#{Config.path(dir)} #{@shared_ca}"}
      File.chmod!(path, if(path == dir, do: 0o700, else: 0o600))
    end

    # A link is followed to the file it names, whose directory is the one checked.
    shared = Path.join(dir, "shared")
    File.mkdir_p!(shared)
    File.rename!(Config.path(dir), Path.join(shared, "config.json"))
    File.ln_s!(Path.join(shared, "config.json"), Config.path(dir))
    File.chmod!(shared, 0o700)
    assert Config.read(dir) == {:ok, config}
    File.chmod!(shared, 0o777)
    assert Config.read(dir) == {:error, :failed, "#{Config.path(dir)} #{@shared_ca}"}

    # Nor is one written through a link to a file others can change, which every later read
    # would refuse.
    File.chmod!(shared, 0o700)
    File.chmod!(Path.join(shared, "config.json"), 0o664)
    assert Config.write(config, dir) == {:error, :failed, "#{Config.path(dir)} #{@shared_ca}"}
    assert Config.write(config(), dir) == :ok
    File.rm!(Config.path(dir))

    # Without a CA, the file is read as before.
    :ok = Config.write(config(), dir)
    File.chmod!(Config.path(dir), 0o664)
    assert Config.read(dir) == {:ok, config()}
  end

  test "makes an installation current only if it is known" do
    assert Config.make_current(config(), "staging") == {:ok, config("staging")}

    assert Config.make_current(config(), "nope") ==
             {:error, :invalid, ~s(no installation is named "nope")}
  end

  test "removing the current installation leaves none current, rather than picking one" do
    assert Config.remove(config(), "local") ==
             {:ok,
              %Config{
                current: nil,
                installations: %{"staging" => %{"url" => "https://ehos.staging.example.com"}}
              }}

    assert Config.remove(config(), "staging") ==
             {:ok,
              %Config{
                current: "local",
                installations: %{"local" => %{"url" => "http://ehos.localhost"}}
              }}
  end

  test "talks to --installation, else EHOSCTL_INSTALLATION, else the current one" do
    env = %{"EHOSCTL_INSTALLATION" => "staging"}
    local = {:ok, {"local", %{"url" => "http://ehos.localhost"}}}

    assert Config.select(config("staging"), "local", env) == local

    assert Config.select(config("local"), nil, env) ==
             {:ok, {"staging", %{"url" => "https://ehos.staging.example.com"}}}

    assert Config.select(config(), nil, %{}) == local
    assert Config.select(config(), nil, %{"EHOSCTL_INSTALLATION" => ""}) == local
  end

  test "without an installation to talk to, is not signed in" do
    assert Config.select(config(nil), nil, %{}) ==
             {:error, :not_signed_in, "no installation is current; sign in to one first"}

    assert Config.select(config(), "nope", %{}) ==
             {:error, :not_signed_in, ~s(no installation is named "nope")}
  end

  defp config(current \\ "local") do
    %Config{
      current: current,
      installations: %{
        "local" => %{"url" => "http://ehos.localhost"},
        "staging" => %{"url" => "https://ehos.staging.example.com"}
      }
    }
  end
end
