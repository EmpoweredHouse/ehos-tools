defmodule Ehosctl.TokenStoreTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.TokenStore
  alias Ehosctl.TokenStore.Keychain
  alias Ehosctl.TokenStore.SecretService

  doctest Ehosctl.TokenStore

  @moduletag :tmp_dir

  @secret "refresh-SECRET_token-value"

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

      assert TokenStore.choose(env, nil) ==
               {:error, :failed,
                "EHOSCTL_TOKEN_STORE is keychain, but this system has no keychain that ehosctl " <>
                  "can use. Set EHOSCTL_TOKEN_STORE to file, or unset it."}

      assert TokenStore.choose(%{"EHOSCTL_TOKEN_STORE" => "vault"}, Keychain) ==
               {:error, :invalid,
                ~s(EHOSCTL_TOKEN_STORE is "vault". Set it to keychain or file, or unset it.)}
    end
  end

  describe "TokenStore.File" do
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

        assert TokenStore.File.put(key, @secret) ==
                 {:error, "#{key.dir} is not yours alone (chmod 700 #{key.dir})"}

        refute File.exists?(TokenStore.File.path(key))

        assert TokenStore.write(key.dir, "staging", %{
                 url: key.url,
                 store: :file,
                 renewed_at: ~U[2026-10-28 12:00:00Z],
                 credentials: %{}
               }) ==
                 {:error, :failed,
                  "#{key.dir} is not yours alone. ehosctl keeps sign-ins only in a directory " <>
                    "that you own and that nobody else can read. Run `chmod 700 #{key.dir}`."}
      end
    end
  end

  describe "read/2 and write/3" do
    # A state directory is the user's alone, which ExUnit's own is not.
    setup %{tmp_dir: dir} do
      state = Path.join(dir, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o700)
      %{tmp_dir: state}
    end

    test "a sign-in's file is written and read back whole", %{tmp_dir: dir} do
      now = ~U[2026-10-28 12:00:00Z]

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
        assert TokenStore.read(dir, "staging") == {:ok, %{session | endpoints: nil}}
      end
    end

    test "a sign-in's file ehosctl did not write is an error, not read in part", %{tmp_dir: dir} do
      file = TokenStore.path(dir, "staging", "json")
      File.write!(file, ~s({"version": 2}))

      assert TokenStore.read(dir, "staging") ==
               {:error, :failed, "#{file} is not a sign-in of ehosctl. Run `ehosctl logout`."}
    end
  end

  describe "dir/1" do
    test "the state directory is ~/.local/state/ehosctl when no variable names one" do
      stub_home("/home/someone")
      assert TokenStore.dir(%{"XDG_STATE_HOME" => ""}) == "/home/someone/.local/state/ehosctl"
    end
  end

  describe "with_lock/3" do
    # A state directory is the user's alone, which ExUnit's own is not.
    setup %{tmp_dir: dir} do
      state = Path.join(dir, "state")
      File.mkdir_p!(state)
      File.chmod!(state, 0o700)
      %{tmp_dir: state}
    end

    test "holds the lock while the function runs, and removes it", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")

      # The lock names this process and a tag of its own, which the test cannot know.
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
      stub_virtual_clock()

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == :ran
    end

    test "removes a lock left empty for ten seconds, by the clock it waits by",
         %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")
      File.write!(lock, "")
      stub_virtual_clock()
      File.touch!(lock, DateTime.to_unix(Ehosctl.Clock.current().now()))

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == :ran
      # Older than ten seconds first at the check of second eleven, and taken a poll later.
      assert Ehosctl.Clock.current().monotonic() == 11_100
    end

    test "removes a lock naming no process for ten seconds, as one left empty", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")

      for id <- ["0 tag", "-1 tag"] do
        File.write!(lock, id)
        stub_virtual_clock()
        File.touch!(lock, DateTime.to_unix(Ehosctl.Clock.current().now()))

        assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == :ran
        assert Ehosctl.Clock.current().monotonic() == 11_100
      end
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
      assert_raise RuntimeError, "boom", fn ->
        TokenStore.with_lock(dir, "staging", fn -> raise "boom" end)
      end

      refute File.exists?(TokenStore.path(dir, "staging", "lock"))
    end

    test "leaves a lock the first version wrote while its process runs", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")
      File.write!(lock, System.pid())
      stub_virtual_clock()
      File.touch!(lock, DateTime.to_unix(Ehosctl.Clock.current().now()))
      # Only this process runs: no `kill` is forked to ask, on each of two minutes' checks.
      stub(Ehosctl.OSMock, :alive?, &(Integer.to_string(&1) == System.pid()))

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == renewing(lock)

      File.write!(lock, dead_pid())
      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == :ran
    end

    test "waits its two minutes by the clock it sleeps by", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")
      File.write!(lock, System.pid() <> " another-command")
      stub_virtual_clock()
      File.touch!(lock, DateTime.to_unix(Ehosctl.Clock.current().now()))
      # The process holding it runs: no `kill` is forked to ask.
      stub(Ehosctl.OSMock, :alive?, fn _pid -> true end)

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == renewing(lock)
      assert Ehosctl.Clock.current().monotonic() == 120_000
    end

    test "never breaks a breaker left behind, and names it", %{tmp_dir: dir} do
      lock = TokenStore.path(dir, "staging", "lock")
      File.write!(lock, dead_pid() <> " tag")
      File.write!(lock <> ".break", dead_pid() <> " tag")
      File.touch!(lock <> ".break", System.os_time(:second) - 3600)
      stub_virtual_clock()
      stub(Ehosctl.OSMock, :alive?, fn _pid -> false end)

      assert TokenStore.with_lock(dir, "staging", fn -> :ran end) == renewing(lock)
      assert File.exists?(lock)
    end
  end

  describe "Keychain and SecretService" do
    # The pipeline runs for real, into fakes of the tools.
    setup do
      stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)
      :ok
    end

    # The pipeline runs for real, into a program that writes down what it was given.
    test "security -i is given the secret on its standard input, in hexadecimal", %{
      tmp_dir: dir
    } do
      fake = recorder(dir, "security")
      command = Keychain.command(:put, key(dir), @secret)

      assert Keychain.run(%{
               command
               | script: String.replace(command.script, "/usr/bin/security", ~s("#{fake}"))
             }) == {"", 0}

      assert File.read!(Path.join(dir, "security.argv")) == "-i\n"
      refute File.read!(Path.join(dir, "security.env")) =~ Base.encode16(@secret, case: :lower)

      assert File.read!(Path.join(dir, "security.stdin")) ==
               "add-generic-password -U -s ehosctl:https://ehos.example.com -a staging -X " <>
                 Base.encode16(@secret, case: :lower) <> "\n"
    end

    test "secret-tool store is given the secret on its standard input", %{tmp_dir: dir} do
      fake = recorder(dir, "secret-tool")
      command = SecretService.command(:put, key(dir), @secret)

      assert Keychain.run(%{
               command
               | script: String.replace(command.script, "secret-tool", ~s("#{fake}"))
             }) == {"", 0}

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
  end

  defp key(dir),
    do: %{dir: Path.join(dir, "state"), name: "staging", url: "https://ehos.example.com"}

  defp renewing(lock) do
    {:error, :failed,
     "another ehosctl is renewing this sign-in; if none is running, remove #{lock} " <>
       "and #{lock}.break"}
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
