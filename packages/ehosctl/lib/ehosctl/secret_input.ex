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
  stopped. A pipe or a file has none of that. The refusal gives instead a command that reads the
  value in the person's shell, which does not show it, and pipes it to ehosctl (`hidden/3`).
  """

  alias Ehosctl.Failure
  alias Ehosctl.Refusal
  alias Ehosctl.Terminal
  alias EhosPlatform.Shell

  @typedoc """
  The words of the refusals, for what is read:

    * `:subject` — what is read, at the start of a sentence: `"The value"`;
    * `:of` — what is read, inside one: `"the value of smtp_password"`;
    * `:most` — why `max` is the bound: `"the most that EHOS accepts"`;
    * `:nothing` — the sentence that says nothing changed: `"Nothing was set."`;
    * `:from` — the sentence that says where it is read from instead of a terminal;
    * `:advice` and `:to_do` — what to do instead, and the commands that do it, as
      `Ehosctl.Failure` holds them.
  """
  @type texts :: %{
          subject: String.t(),
          of: String.t(),
          most: String.t(),
          nothing: String.t(),
          from: String.t(),
          advice: String.t() | nil,
          to_do: [String.t()]
        }

  @doc """
  The bytes of the file at `path`, as it holds them, or of standard input for `:stdin`, at most
  `max` of them and the line break `echo` adds; standard input that is a terminal, and a path to
  a device, are refused. A
  value longer than that is refused, as is one that cannot be read, in the words of `texts`.
  Read as bytes: the caller judges whether they are text.
  """
  @spec read(Path.t() | :stdin, pos_integer(), texts()) ::
          {:ok, binary()} | {:error, :invalid, Failure.message()}
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

  @doc """
  The advice and the command that read a value in the person's shell without showing it, and
  give it to `command` through a pipe, for the shell that `shell`, the variable `SHELL`, names:
  zsh's `read` or bash's. The shell asks for the value with `prompt`, and keeps it in the
  variable `v` of a subshell, which ends with the command, also on Ctrl-C. `unset v` and
  `set +a` first keep it out of ehosctl's environment, where an exported `v` or `allexport`
  would put it; `IFS=` keeps the spaces at the start and at the end. The value is never in a file or in
  the shell's history. Another shell gets the advice alone, since its `read` hides nothing or
  takes other options.

  A shell reads a line as the terminal gives it, which on macOS is 1 KiB at most: a longer
  paste never ends the line, so the advice sends a longer value to `file`, the option that reads
  a file.

      iex> Ehosctl.SecretInput.hidden("ehosctl secrets set smtp_password --app ledger --env try",
      ...>   {"Value of smtp_password: ", "--from-file"}, "/bin/zsh")
      {"For a value of more than 1000 characters, give --from-file. For a shorter value, run " <>
         "this command in zsh. It does not show what you type:",
       ["(unset v; set +a; IFS= read -rs 'v?Value of smtp_password: ' && echo && printf '%s' \"$v\" | " <>
          "ehosctl secrets set smtp_password --app ledger --env try)"]}

      iex> Ehosctl.SecretInput.hidden("ehosctl secrets set smtp_password --app ledger --env try",
      ...>   {"Value of smtp_password: ", "--from-file"}, "/usr/bin/fish")
      {"Give the value with --from-file, or through a pipe.", []}
  """
  @spec hidden(String.t(), {String.t(), String.t()}, String.t() | nil) ::
          {String.t(), [String.t()]}
  def hidden(command, {prompt, file}, shell) do
    case read_hidden(Path.basename(shell || ""), prompt) do
      {name, read} ->
        {"For a value of more than 1000 characters, give #{file}. For a shorter value, run " <>
           "this command in #{name}. It does not show what you type:",
         ["(unset v; set +a; " <> read <> " && echo && printf '%s' \"$v\" | " <> command <> ")"]}

      nil ->
        {"Give the value with #{file}, or through a pipe.", []}
    end
  end

  defp read_hidden("zsh", prompt), do: {"zsh", "IFS= read -rs " <> Shell.word("v?" <> prompt)}
  defp read_hidden("bash", prompt), do: {"bash", "IFS= read -rsp " <> Shell.word(prompt) <> " v"}
  defp read_hidden(_shell, _prompt), do: nil

  defp at_terminal(texts),
    do:
      {:error, :invalid,
       Failure.new(texts.nothing,
         reason:
           "ehosctl does not read #{texts.of} from a terminal, which can show or keep it. " <>
             texts.from,
         advice: texts.advice,
         to_do: texts.to_do
       )}

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
