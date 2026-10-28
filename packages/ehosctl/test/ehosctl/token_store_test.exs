defmodule Ehosctl.TokenStoreTest do
  use Ehosctl.Case, async: true

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

    test "refuses a directory others can read or write", %{tmp_dir: dir} do
      key = key(dir)
      File.mkdir_p!(key.dir)

      for mode <- [0o777, 0o755, 0o750] do
        File.chmod!(key.dir, mode)

        assert {:error, message} = TokenStore.File.put(key, @secret)
        assert message =~ "is not yours alone"
        refute File.exists?(TokenStore.File.path(key))

        assert {:error, :failed, message} =
                 TokenStore.write(key.dir, "staging", %{
                   url: key.url,
                   store: :file,
                   renewed_at: DateTime.utc_now(:second),
                   credentials: %{}
                 })

        assert message =~ "chmod 700"
      end
    end
  end

  describe "the sign-in's file" do
    # A state directory is the user's alone, which ExUnit's own is not.
    setup %{tmp_dir: dir} do
      state = Path.join(dir, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o700)
      %{tmp_dir: state}
    end

    test "is written and read back whole", %{tmp_dir: dir} do
      now = DateTime.utc_now(:second)

      session = %{
        url: "https://ehos.example.com",
        store: :keychain,
        renewed_at: now,
        credentials: %{"https://ehos.example.com" => %{token: "c", expires_at: now}},
        endpoints: %{"token" => "https://ehos.example.com/oauth/token", "revocation" => nil}
      }

      assert TokenStore.read(dir, "staging") == :none
      assert TokenStore.write(dir, "staging", session) == :ok
      assert TokenStore.read(dir, "staging") == {:ok, session}
      assert mode(TokenStore.path(dir, "staging", "json")) == 0o600

      # One kept with no endpoints, or endpoints of another shape, reads with none.
      for endpoints <- [nil, %{"token" => 1}] do
        :ok = TokenStore.write(dir, "staging", %{session | endpoints: endpoints})
        assert {:ok, %{endpoints: nil}} = TokenStore.read(dir, "staging")
      end
    end

    test "one ehosctl did not write is an error, not read in part", %{tmp_dir: dir} do
      File.write!(TokenStore.path(dir, "staging", "json"), ~s({"version": 2}))
      assert {:error, :failed, message} = TokenStore.read(dir, "staging")
      assert message =~ "is not an ehosctl sign-in; run `ehosctl logout`"
    end
  end

  describe "with_lock/4" do
    # A state directory is the user's alone, which ExUnit's own is not.
    setup %{tmp_dir: dir} do
      state = Path.join(dir, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o700)
      %{tmp_dir: state}
    end

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

    test "leaves a lock the first version wrote while its process runs", %{tmp_dir: dir} do
      File.write!(TokenStore.path(dir, "staging", "lock"), System.pid())

      assert {:error, :failed, _} =
               TokenStore.with_lock(dir, "staging", fn -> :ran end, timeout: 300)

      File.write!(TokenStore.path(dir, "staging", "lock"), dead_pid())
      assert TokenStore.with_lock(dir, "staging", fn -> :ran end, timeout: 1_000) == :ran
    end

    test "never breaks a breaker left behind, and names it", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")
      File.write!(lock, dead_pid() <> " tag")
      File.write!(lock <> ".break", dead_pid() <> " tag")
      File.touch!(lock <> ".break", System.os_time(:second) - 3600)

      assert {:error, :failed, message} =
               TokenStore.with_lock(dir, "staging", fn -> :ran end, timeout: 300)

      assert message =~ "remove #{lock} and #{lock}.break"
      assert File.exists?(lock)
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
    # The pipeline runs for real, into fakes of the tools.
    setup do
      stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)
      :ok
    end

    # secret-tool says nothing and exits 1 for an item that is not there, and says why and exits
    # 1 for a D-Bus or keyring that failed, which is not the same.
    test "secret-tool lookup tells a failure from an item that is not there", %{tmp_dir: dir} do
      command = SecretService.command(:get, key(dir), nil)

      for {name, body, status} <- [
            {"absent", "exit 1", 1},
            {"broken", "echo 'Cannot autolaunch D-Bus' >&2; exit 1", 2}
          ] do
        fake = Path.join(dir, name)
        File.write!(fake, "#!/bin/sh\n#{body}\n")
        File.chmod!(fake, 0o700)
        script = String.replace(command.script, "secret-tool", ~s("#{fake}"))
        assert Keychain.run(%{command | script: script}) == {"", status}, name
      end
    end

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
      refute File.read!(Path.join(dir, "security.env")) =~ Base.encode16(@secret, case: :lower)

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
      refute File.read!(Path.join(dir, "secret-tool.env")) =~ @secret
    end

    # A tool that warns on its error stream and prints the secret on its standard output.
    test "a read takes the secret alone, without what the tool warns of", %{tmp_dir: dir} do
      fake = Path.join(dir, "warns")
      File.write!(fake, "#!/bin/sh\nprintf 'GLib-WARNING: no dbus\\n' >&2\nprintf '#{@secret}'\n")
      File.chmod!(fake, 0o700)

      for {backend, tool} <- [{Keychain, "/usr/bin/security"}, {SecretService, "secret-tool"}] do
        command = backend.command(:get, key(dir), nil)
        script = String.replace(command.script, tool, ~s("#{fake}"))
        assert Keychain.run(%{command | script: script}) == {@secret, 0}, inspect(backend)
      end
    end
  end

  # A program at `dir/<name>` that writes its arguments and its standard input beside it.
  defp recorder(dir, name) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "#{path}.argv"
    env > "#{path}.env"
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
