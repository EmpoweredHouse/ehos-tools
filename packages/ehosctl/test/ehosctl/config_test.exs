defmodule Ehosctl.ConfigTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Ehosctl.Config

  doctest Ehosctl.Config

  @moduletag :tmp_dir

  defp config(current \\ "local") do
    %Config{
      current: current,
      installations: %{
        "local" => %{"url" => "http://ehos.localhost"},
        "staging" => %{"url" => "https://ehos.staging.example.com"}
      }
    }
  end

  test "is looked for in EHOSCTL_CONFIG_DIR, then XDG_CONFIG_HOME, then ~/.config" do
    assert Config.dir(%{"EHOSCTL_CONFIG_DIR" => "/e", "XDG_CONFIG_HOME" => "/x"}) == "/e"
    assert Config.dir(%{"EHOSCTL_CONFIG_DIR" => "", "XDG_CONFIG_HOME" => "/x"}) == "/x/ehosctl"

    assert Config.dir(%{"XDG_CONFIG_HOME" => ""}) ==
             Path.join(System.user_home!(), ".config/ehosctl")
  end

  test "a directory without a configuration holds no installations", %{tmp_dir: dir} do
    assert Config.read(Path.join(dir, "none")) == {:ok, %Config{}}
  end

  test "writes the documented shape, and reads back what it wrote", %{tmp_dir: dir} do
    dir = Path.join(dir, "ehosctl")
    assert Config.write(config(), dir) == :ok

    assert dir |> Config.path() |> File.read!() |> JSON.decode!() == %{
             "version" => 1,
             "current" => "local",
             "installations" => %{
               "local" => %{"url" => "http://ehos.localhost"},
               "staging" => %{"url" => "https://ehos.staging.example.com"}
             }
           }

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

  test "carries what a later ehosctl keeps beside an installation's URL", %{tmp_dir: dir} do
    File.write!(
      Config.path(dir),
      ~s({"version":1,"current":null,"installations":{"a":{"url":"u","signed_in_as":"x"}}})
    )

    {:ok, config} = Config.read(dir)
    :ok = Config.write(config, dir)
    assert {:ok, %Config{installations: %{"a" => %{"signed_in_as" => "x"}}}} = Config.read(dir)
  end

  test "refuses a file a newer ehosctl wrote, and leaves it as it was", %{tmp_dir: dir} do
    newer = ~s({"version":2,"installations":{}})
    File.write!(Config.path(dir), newer)

    assert {:error, :failed, message} = Config.read(dir)
    assert message =~ "written by a newer ehosctl"
    assert File.read!(Config.path(dir)) == newer
  end

  test "refuses a file that is not a configuration, saying which file", %{tmp_dir: dir} do
    for contents <- [
          "{not json",
          ~s({"version":1}),
          ~s({"version":1,"installations":{"Bad Name":{}}}),
          ~s({"version":1,"current":"gone","installations":{}}),
          ~s({"version":1,"installations":{"a":{}}}),
          ~s({"version":1,"installations":{"a":{"url":27}}}),
          ~s({"version":1,"installations":{"a":{"url":null}}}),
          ~s({"version":1,"installations":{"a":{"url":"x\\u001b]0;pwned\\u0007y"}}})
        ] do
      File.write!(Config.path(dir), contents)
      assert {:error, :failed, message} = Config.read(dir)
      assert message =~ Config.path(dir)
    end
  end

  test "makes an installation current only if it is known" do
    assert {:ok, %Config{current: "staging"}} = Config.make_current(config(), "staging")
    assert {:error, :invalid, _} = Config.make_current(config(), "nope")
  end

  test "removing the current installation leaves none current, rather than picking one" do
    assert {:ok, %Config{current: nil, installations: installations}} =
             Config.remove(config(), "local")

    assert Map.keys(installations) == ["staging"]
    assert {:ok, %Config{current: "local"}} = Config.remove(config(), "staging")
  end

  test "talks to --installation, else EHOSCTL_INSTALLATION, else the current one" do
    env = %{"EHOSCTL_INSTALLATION" => "staging"}

    assert {:ok, {"local", _}} = Config.select(config("staging"), "local", env)
    assert {:ok, {"staging", _}} = Config.select(config("local"), nil, env)

    assert {:ok, {"local", %{"url" => "http://ehos.localhost"}}} =
             Config.select(config(), nil, %{})

    assert {:ok, {"local", _}} = Config.select(config(), nil, %{"EHOSCTL_INSTALLATION" => ""})
  end

  test "without an installation to talk to, is not signed in" do
    assert {:error, :not_signed_in, _} = Config.select(config(nil), nil, %{})
    assert {:error, :not_signed_in, message} = Config.select(config(), "nope", %{})
    assert message =~ ~s("nope")
  end
end
