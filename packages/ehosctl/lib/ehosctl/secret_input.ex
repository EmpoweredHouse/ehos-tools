defmodule Ehosctl.SecretInput do
  @moduledoc """
  Reads a value a person must not type on the command line, such as a secret's value or a
  password: from a file, as the file holds it, or from standard input, a pipe or a file; never
  typed at a terminal, which would show or keep it. Neither is read past a bound, so a device or a
  huge file is refused rather than read into memory. A path to a device, such as `/dev/tty`, is
  refused as a terminal is; a pipe, such as a path that `<(…)` gives, is read. `ehosctl secrets set` and
  `ehosctl resources add-database` read their values through it.

  A value typed at a terminal is not read. This binary is a release without a shell, which has
  neither `:io.get_password/0` nor a raw mode, and the terminal's own line discipline would then
  decide what is read: it cuts or holds a long line, hands what is not read to the shell, echoes
  whatever is typed before `stty` turns echo off, and is left without echo when the process is
  stopped. A pipe or a file has none of that.
  """

  alias Ehosctl.Refusal
  alias Ehosctl.Terminal

  @typedoc """
  The words of the refusals, for what is read:

    * `:subject` — what is read, at the start of a sentence: `"The value"`;
    * `:of` — what is read, inside one: `"the value of smtp_password"`;
    * `:most` — why `max` is the bound: `"the most that EHOS accepts"`;
    * `:nothing` — the sentence that says nothing changed: `"Nothing was set."`;
    * `:give` — the sentences that say how to give it instead of at a terminal.
  """
  @type texts :: %{
          subject: String.t(),
          of: String.t(),
          most: String.t(),
          nothing: String.t(),
          give: String.t()
        }

  @doc """
  The bytes of the file at `path`, as it holds them, or of standard input for `:stdin`, at most
  `max` of them and the line break `echo` adds; standard input that is a terminal, and a path to
  a device, are refused. A
  value longer than that is refused, as is one that cannot be read, in the words of `texts`.
  Read as bytes: the caller judges whether they are text.
  """
  @spec read(Path.t() | :stdin, pos_integer(), texts()) ::
          {:ok, binary()} | {:error, :invalid, String.t()}
  def read(:stdin, max, texts) do
    if Terminal.current().input_terminal?() do
      at_terminal(texts)
    else
      max |> read_bytes() |> Terminal.current().read_input() |> bounded(max, texts)
    end
  end

  # A device, such as `/dev/tty`, or `/dev/stdin` at a terminal, is a terminal read with echo on:
  # refused as standard input at a terminal is. A pipe, such as `<(…)`, is read.
  # sobelow_skip ["Traversal.FileModule"]
  def read(path, max, texts) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :device}} -> at_terminal(texts)
      _other -> read_file(path, max, texts)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path, max, texts) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          device |> IO.binread(read_bytes(max)) |> bounded(max, texts)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, :invalid,
         "#{Refusal.shown(path)}: ehosctl cannot read it (#{reason(reason)}). #{texts.nothing}"}
    end
  end

  @doc """
  The refusal of a value longer than `max` bytes, in the words of `texts`, for a caller that
  checks the length of what it read again.
  """
  @spec too_long(pos_integer(), texts()) :: String.t()
  def too_long(max, texts),
    do: "#{texts.subject} is longer than #{max} bytes, #{texts.most}. #{texts.nothing}"

  @doc """
  `value` without the one line break `echo` ends it with, `\\n` or `\\r\\n`.

      iex> Ehosctl.SecretInput.chomp("s3cret\\r\\n")
      "s3cret"

      iex> Ehosctl.SecretInput.chomp("s3cret\\n\\n")
      "s3cret\\n"
  """
  @spec chomp(binary()) :: binary()
  def chomp(value) do
    cond do
      String.ends_with?(value, "\r\n") -> binary_part(value, 0, byte_size(value) - 2)
      String.ends_with?(value, "\n") -> binary_part(value, 0, byte_size(value) - 1)
      true -> value
    end
  end

  defp at_terminal(texts),
    do:
      {:error, :invalid,
       "ehosctl does not read #{texts.of} from a terminal, which can show or keep it. " <>
         "#{texts.nothing} #{texts.give}"}

  # What a read takes at most: the value, the line break `echo` ends it with, and one byte to tell
  # a value too long.
  defp read_bytes(max), do: max + 3

  defp bounded(read, max, texts) do
    limit = read_bytes(max)

    case read do
      data when is_binary(data) and byte_size(data) == limit ->
        {:error, :invalid, too_long(max, texts)}

      data when is_binary(data) ->
        {:ok, data}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, :invalid,
         "#{texts.subject}: ehosctl cannot read it (#{reason(reason)}). #{texts.nothing}"}
    end
  end

  defp reason(reason) when is_atom(reason), do: :file.format_error(reason)
  defp reason(reason), do: inspect(reason)
end
