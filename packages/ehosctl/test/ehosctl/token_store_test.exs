defmodule Ehosctl.TokenStoreTest do
  use ExUnit.Case, async: true

  alias Ehosctl.TokenStore
  alias Ehosctl.TokenStore.Keychain
  alias Ehosctl.TokenStore.SecretService

  doctest Ehosctl.TokenStore

  @moduletag :tmp_dir

  @secret "refresh-SECRET_token-value"

  defp key(dir),
    do: %{dir: Path.join(dir, "state"), name: "staging", url: "https://ehos.example.com"}

  describe "choose/2" do
    test "the keychain first, then the file, by default" do
      assert TokenStore.choose(%{}, Keychain) ==
               {:ok, [keychain: Keychain, file: TokenStore.File]}

      assert TokenStore.choose(%{"EHOSCTL_TOKEN_STORE" => ""}, nil) ==
               {:ok, [file: TokenStore.File]}
    end

    test "EHOSCTL_TOKEN_STORE chooses one" do
      env = %{"EHOSCTL_TOKEN_STORE" => "file"}
      assert TokenStore.choose(env, Keychain) == {:ok, [file: TokenStore.File]}

      env = %{"EHOSCTL_TOKEN_STORE" => "keychain"}
      assert TokenStore.choose(env, Keychain) == {:ok, [keychain: Keychain]}
      assert {:error, :failed, _} = TokenStore.choose(env, nil)

      assert {:error, :invalid, message} =
               TokenStore.choose(%{"EHOSCTL_TOKEN_STORE" => "vault"}, Keychain)

      assert message =~ "it is keychain or file"
    end
  end

  describe "the file" do
    test "keeps the token 0600 in a 0700 directory", %{tmp_dir: dir} do
      key = key(dir)
      assert TokenStore.File.get(key) == :none
      assert TokenStore.File.put(key, @secret) == :ok

      assert TokenStore.File.get(key) == {:ok, @secret}
      assert mode(TokenStore.File.path(key)) == 0o600
      assert mode(key.dir) == 0o700

      assert TokenStore.File.delete(key) == :ok
      assert TokenStore.File.get(key) == :none
      assert TokenStore.File.delete(key) == :ok
    end

    test "refuses a directory others can write to", %{tmp_dir: dir} do
      key = key(dir)
      File.mkdir_p!(key.dir)
      File.chmod!(key.dir, 0o777)

      assert {:error, message} = TokenStore.File.put(key, @secret)
      assert message =~ "can be written by others"
    end
  end

  describe "the sign-in's file" do
    test "is written and read back whole", %{tmp_dir: dir} do
      now = DateTime.utc_now(:second)

      session = %{
        url: "https://ehos.example.com",
        store: :keychain,
        renewed_at: now,
        credentials: %{"https://ehos.example.com" => %{token: "c", expires_at: now}}
      }

      assert TokenStore.read(dir, "staging") == :none
      assert TokenStore.write(dir, "staging", session) == :ok
      assert TokenStore.read(dir, "staging") == {:ok, session}
      assert mode(TokenStore.path(dir, "staging", "json")) == 0o600
    end

    test "one ehosctl did not write is an error, not read in part", %{tmp_dir: dir} do
      File.write!(TokenStore.path(dir, "staging", "json"), ~s({"version": 2}))
      assert {:error, :failed, message} = TokenStore.read(dir, "staging")
      assert message =~ "is not an ehosctl sign-in; run `ehosctl logout`"
    end
  end

  describe "with_lock/4" do
    test "holds the lock while the function runs, and removes it", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")

      assert TokenStore.with_lock(dir, "staging", fn -> File.read!(lock) end) =~
               ~r/\A#{System.pid()} \S+\z/
      refute File.exists?(lock)
    end

    test "a second waits for the first", %{tmp_dir: dir} do
      test = self()

      first =
        Task.async(fn ->
          TokenStore.with_lock(dir, "staging", fn ->
            send(test, :first_holds)
            Process.sleep(300)
            :first
          end)
        end)

      assert_receive :first_holds
      started = System.monotonic_time(:millisecond)
      assert TokenStore.with_lock(dir, "staging", fn -> :second end) == :second
      assert System.monotonic_time(:millisecond) - started >= 200
      assert Task.await(first) == :first
    end

    test "removes a lock whose process no longer runs", %{tmp_dir: dir} do
      File.write!(TokenStore.path(dir, "staging", "lock"), dead_pid() <> " tag")

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end, timeout: 1_000) == :ran
    end

    test "commands that find a stale lock at once take it one at a time", %{tmp_dir: dir} do
      File.write!(TokenStore.path(dir, "staging", "lock"), dead_pid() <> " tag")
      inside = :counters.new(2, [:atomics])

      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          TokenStore.with_lock(dir, "staging", fn ->
            :counters.add(inside, 1, 1)
            # The most commands ever inside at once.
            max = max(:counters.get(inside, 2), :counters.get(inside, 1))
            :counters.put(inside, 2, max)
            Process.sleep(20)
            :counters.sub(inside, 1, 1)
          end)
        end)
      end)
      |> Task.await_many(30_000)

      assert :counters.get(inside, 2) == 1
    end

    test "leaves a lock that is no longer its own", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")

      TokenStore.with_lock(dir, "staging", fn -> File.write!(lock, "1 another") end)
      assert File.read!(lock) == "1 another"
    end

    test "is removed when the function raises", %{tmp_dir: dir} do
      assert_raise RuntimeError, fn ->
        TokenStore.with_lock(dir, "staging", fn -> raise "boom" end)
      end

      refute File.exists?(TokenStore.path(dir, "staging", "lock"))
    end
  end

  describe "the keychain commands" do
    for backend <- [Keychain, SecretService] do
      test "#{inspect(backend)} never puts the secret on a command line", %{tmp_dir: dir} do
        for operation <- [:put, :get, :delete] do
          command =
            unquote(backend).command(operation, key(dir), if(operation == :put, do: @secret))

          refute command.script =~ @secret
          refute Enum.any?(command.args, &(&1 =~ @secret))
          refute command.script =~ Base.encode16(@secret, case: :lower)
          refute Enum.any?(command.args, &(&1 =~ Base.encode16(@secret, case: :lower)))
        end
      end
    end

    # The pipeline runs for real, into a program that writes down what it was given.
    test "security -i is given the secret on its standard input, in hexadecimal", %{
      tmp_dir: dir
    } do
      fake = recorder(dir, "security")
      command = Keychain.command(:put, key(dir), @secret)

      assert {_output, 0} =
               Keychain.run(%{
                 command
                 | script: String.replace(command.script, "/usr/bin/security", ~s("#{fake}"))
               })

      assert File.read!(Path.join(dir, "security.argv")) == "-i\n"

      assert File.read!(Path.join(dir, "security.stdin")) ==
               "add-generic-password -U -s ehosctl:https://ehos.example.com -a staging -X " <>
                 Base.encode16(@secret, case: :lower) <> "\n"
    end

    test "secret-tool store is given the secret on its standard input", %{tmp_dir: dir} do
      fake = recorder(dir, "secret-tool")
      command = SecretService.command(:put, key(dir), @secret)

      assert {_output, 0} =
               Keychain.run(%{
                 command
                 | script: String.replace(command.script, "secret-tool", ~s("#{fake}"))
               })

      assert File.read!(Path.join(dir, "secret-tool.argv")) ==
               "store\n--label=ehosctl: staging\nservice\nehosctl:https://ehos.example.com\naccount\nstaging\n"

      assert File.read!(Path.join(dir, "secret-tool.stdin")) == @secret
    end
  end

  # A program at `dir/<name>` that writes its arguments and its standard input beside it.
  defp recorder(dir, name) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "#{path}.argv"
    cat > "#{path}.stdin"
    """)

    File.chmod!(path, 0o700)
    path
  end

  # The id of a process that has exited.
  defp dead_pid do
    {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.trim(pid)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
