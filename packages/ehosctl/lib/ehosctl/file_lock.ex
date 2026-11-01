defmodule Ehosctl.FileLock do
  @moduledoc """
  A lock one `ehosctl` holds against every other on the same machine, as a file: a sign-in's
  while it is renewed (`Ehosctl.TokenStore.with_lock/3`, T-08).
  """

  # How long a command waits for another, and how often it looks: longer than one renewal can
  # take, three requests of thirty seconds each.
  @timeout_ms 120_000
  @poll_ms 100
  @check_every 10
  # A lock file with no process id in it yet is one being created, unless it is older than this.
  @unwritten_ms 10_000

  @doc """
  Runs `fun` holding the lock `lock`, a file whose directory exists, and returns what it returns.

  The lock is created exclusively with the process's id and a random tag in it, and removed when
  `fun` returns or raises, but only while it is still this one's. A command that finds it waits
  for up to two minutes, by `Ehosctl.Clock`, and then fails with `busy`, which says who holds it,
  and which files to remove if nobody does.

  A lock whose process no longer runs is broken, one breaker at a time: under `<lock>.break`,
  itself created exclusively, the lock is read again and removed only if it is still the dead
  one. Two commands that found it stale cannot both remove it and take it in turn.
  """
  @spec with_lock(Path.t(), String.t(), (-> result)) ::
          result | {:error, :failed, String.t()}
        when result: term()
  def with_lock(lock, busy, fun) do
    deadline = Ehosctl.Clock.current().monotonic() + @timeout_ms
    own = "#{System.pid()} #{Base.url_encode64(:crypto.strong_rand_bytes(9))}"

    with :ok <- acquire(lock, own, busy, deadline, 0) do
      try do
        fun.()
      after
        release(lock, own)
      end
    end
  end

  defp release(file, own) do
    if File.read(file) == {:ok, own}, do: File.rm(file)
  end

  defp acquire(lock, own, busy, deadline, polls) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, device} ->
        # A lock left empty would be taken for one being written, and removed by nobody.
        written =
          with :ok <- :file.write(device, own), do: File.close(device)

        case written do
          :ok ->
            :ok

          {:error, reason} ->
            File.close(device)
            File.rm(lock)
            {:error, :failed, "cannot write #{lock}: #{:file.format_error(reason)}"}
        end

      {:error, :eexist} ->
        # Whether its process runs is asked once a second, not on every poll: it forks `kill`.
        if rem(polls, @check_every) == 0, do: break_if_stale(lock)

        if Ehosctl.Clock.current().monotonic() >= deadline do
          {:error, :failed, "#{busy}; if none is running, remove #{lock} and #{lock}.break"}
        else
          Ehosctl.Clock.current().sleep(@poll_ms)
          acquire(lock, own, busy, deadline, polls + 1)
        end

      {:error, reason} ->
        {:error, :failed, "cannot create #{lock}: #{:file.format_error(reason)}"}
    end
  end

  defp break_if_stale(lock) do
    with {:ok, contents} <- File.read(lock),
         true <- stale?(lock, contents) do
      breaker = lock <> ".break"
      own = "#{System.pid()} #{Base.url_encode64(:crypto.strong_rand_bytes(9))}"

      # A breaker is held for a read and a removal. One left by a command that died in between is
      # never broken here, which would let two breakers in: the timeout's message names it.
      case File.open(breaker, [:write, :exclusive]) do
        {:ok, device} ->
          break(device, breaker, own, lock, contents)

        {:error, _another_breaker} ->
          :ok
      end
    end
  end

  defp break(device, breaker, own, lock, contents) do
    written = with :ok <- :file.write(device, own), do: File.close(device)

    try do
      if written == :ok and File.read(lock) == {:ok, contents}, do: File.rm(lock)
    after
      # Removed as its own, or, when it could not be written whole, for nobody else would.
      if written == :ok, do: release(breaker, own), else: File.rm(breaker)
    end
  end

  # A lock is stale when the process that holds it no longer runs. One with no id in it is being
  # created, unless it has been empty for longer than it takes to write one.
  defp stale?(lock, contents) do
    case Integer.parse(contents) do
      # The id alone is what the first version wrote.
      {pid, rest} when rest == "" or binary_part(rest, 0, 1) == " " ->
        not Ehosctl.OS.current().alive?(pid)

      _unwritten ->
        older_than?(lock, @unwritten_ms)
    end
  end

  # Read by `Ehosctl.Clock`, as the wait is, so a test's virtual clock ages a lock too.
  defp older_than?(file, ms) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        DateTime.to_unix(Ehosctl.Clock.current().now(), :millisecond) - mtime * 1000 > ms

      {:error, _} ->
        false
    end
  end
end
