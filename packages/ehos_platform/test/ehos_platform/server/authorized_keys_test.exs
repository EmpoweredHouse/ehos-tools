defmodule EhosPlatform.Server.AuthorizedKeysTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Server.AuthorizedKeys

  doctest AuthorizedKeys

  describe "parse/1 and render/1" do
    test "reads each kind of line and writes the file back as it was" do
      ada = key("ssh-ed25519", 1)
      shared = key("ssh-ed25519", 2)
      agent = key("ecdsa-sha2-nistp256", 3)
      hand = key("ssh-rsa", 4)

      contents =
        "#{line(ada)} ehos-administrator:ada:1a2b3c4d\n" <>
          "#{line(shared)} ehos-administrator:shared\n" <>
          "# Added by Google\n#{line(agent)} ada@example.com\n" <>
          "from=\"192.0.2.0/24\" #{line(hand)} kept by hand\n" <>
          "\n# a comment\nnot a key\n"

      lines = AuthorizedKeys.parse(contents)

      assert Enum.map(lines, &Map.delete(&1, :text)) == [
               %{
                 kind: :named,
                 key: ada,
                 comment: "ehos-administrator:ada:1a2b3c4d",
                 options: nil,
                 name: "ada",
                 id: "1a2b3c4d"
               },
               %{
                 kind: :named,
                 key: shared,
                 comment: "ehos-administrator:shared",
                 options: nil,
                 name: "shared",
                 id: nil
               },
               %{
                 kind: :agent,
                 key: agent,
                 comment: "ada@example.com",
                 options: nil,
                 name: nil,
                 id: nil
               },
               %{
                 kind: :unnamed,
                 key: hand,
                 comment: "kept by hand",
                 options: ~s(from="192.0.2.0/24"),
                 name: nil,
                 id: nil
               },
               %{kind: :other, key: nil, comment: "", options: nil, name: nil, id: nil},
               %{kind: :other, key: nil, comment: "", options: nil, name: nil, id: nil},
               %{kind: :unreadable, key: nil, comment: "", options: nil, name: nil, id: nil}
             ]

      assert AuthorizedKeys.render(lines) == contents
    end

    test "keeps a file without a last newline, and an empty one, as they were read" do
      ada = key("ssh-ed25519", 1)

      assert "#{line(ada)} ada" |> AuthorizedKeys.parse() |> AuthorizedKeys.render() ==
               "#{line(ada)} ada\n"

      assert "" |> AuthorizedKeys.parse() |> AuthorizedKeys.render() == ""
    end

    # sshd stops at a NUL, as a C string does, and its blanks are spaces and tabs alone.
    test "reads a line to its first NUL, and only spaces and tabs as blanks" do
      ada = key("ssh-ed25519", 1)

      assert [
               %{kind: :unnamed, key: ^ada, comment: "ada"},
               %{kind: :unreadable, key: nil}
             ] = AuthorizedKeys.parse("#{line(ada)} ada\0junk\n\v#{line(ada)} vertical\n")
    end

    test "reads a comment after blanks as a comment, as sshd does" do
      ada = key("ssh-ed25519", 1)

      assert [%{kind: :other, key: nil}] = AuthorizedKeys.parse("   # #{line(ada)} old\n")
    end

    # A key type quoted inside an option is not the line's key, as sshd reads it.
    test "reads the key after the options field, whatever an option quotes" do
      ada = key("ssh-ed25519", 1)
      mallory = key("ssh-ed25519", 5)

      text =
        ~s(command="echo \\"x\\" #{line(ada)}",no-pty #{line(mallory)} mallory\n) <>
          ~s(cert-authority #{line(mallory)} ca\n)

      assert [
               %{kind: :unnamed, key: ^mallory, comment: "mallory", options: options},
               %{kind: :unnamed, key: ^mallory, comment: "ca", options: "cert-authority"}
             ] = AuthorizedKeys.parse(text)

      assert options == ~s(command="echo \\"x\\" #{line(ada)}",no-pty)
    end

    test "reads a name it does not write, as one with no id, as a key that names nobody" do
      ada = key("ssh-ed25519", 1)

      assert [%{kind: :unnamed, name: nil}, %{kind: :unnamed, name: nil}] =
               AuthorizedKeys.parse(
                 "#{line(ada)} ehos-administrator:ada\n#{line(ada)} ehos-administrator:shared:1a2b3c4d\n"
               )
    end
  end

  describe "public_key/1" do
    test "reads one Ed25519 or ECDSA P-256 key, with or without a comment" do
      ed25519 = key("ssh-ed25519", 1)
      ecdsa = key("ecdsa-sha2-nistp256", 2)

      assert AuthorizedKeys.public_key("#{line(ed25519)} ada@laptop\n") == {:ok, ed25519}
      assert AuthorizedKeys.public_key("\n#{line(ecdsa)}\n\n") == {:ok, ecdsa}
    end

    test "refuses a blob that names its type and holds no whole key" do
      bare = Base.encode64(<<11::32, "ssh-ed25519">>)
      short = Base.encode64(<<11::32, "ssh-ed25519", 31::32, :binary.copy(<<1>>, 31)::binary>>)

      off_curve =
        Base.encode64(
          <<19::32, "ecdsa-sha2-nistp256", 8::32, "nistp256", 65::32, 4,
            :binary.copy(<<1>>, 64)::binary>>
        )

      for {type, blob} <- [
            {"ssh-ed25519", bare},
            {"ssh-ed25519", short},
            {"ecdsa-sha2-nistp256", off_curve}
          ] do
        assert AuthorizedKeys.public_key("#{type} #{blob}\n") ==
                 {:error, "The key in the file is not a #{type} key that OpenSSH reads."}
      end
    end

    test "refuses an empty file, two keys, another type, options, and a blob of another type" do
      ed25519 = key("ssh-ed25519", 1)
      {_type, rsa_blob} = key("ssh-rsa", 2)

      options =
        "The file does not start with an ssh-ed25519 or ecdsa-sha2-nistp256 public key. Give " <>
          "the .pub file of such a key, with no options such as from= or command= before it."

      assert AuthorizedKeys.public_key("\n") == {:error, "The file holds no public key."}

      assert AuthorizedKeys.public_key("#{line(ed25519)}\n#{line(ed25519)}\n") ==
               {:error, "The file holds more than one line. Give a file with one public key."}

      assert AuthorizedKeys.public_key("ssh-rsa #{rsa_blob}\n") == {:error, options}
      assert AuthorizedKeys.public_key("command=\"true\" #{line(ed25519)}\n") == {:error, options}

      assert AuthorizedKeys.public_key("ssh-ed25519 #{rsa_blob}\n") ==
               {:error, "The key in the file is not a ssh-ed25519 key that OpenSSH reads."}
    end
  end

  # A public key of `type` whose blob is told apart by `seed`, as OpenSSH lays one out; a P-256
  # key is a point on the curve, made anew.
  defp key("ecdsa-sha2-nistp256" = type, _seed) do
    {point, _private} = :crypto.generate_key(:ecdh, :prime256v1)
    blob = <<19::32, type::binary, 8::32, "nistp256", 65::32, point::binary>>
    {type, Base.encode64(blob)}
  end

  defp key(type, seed) do
    blob = <<byte_size(type)::32, type::binary, 32::32, :binary.copy(<<seed>>, 32)::binary>>
    {type, Base.encode64(blob)}
  end

  defp line({type, blob}), do: "#{type} #{blob}"
end
