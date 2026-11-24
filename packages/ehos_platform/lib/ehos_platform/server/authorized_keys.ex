defmodule EhosPlatform.Server.AuthorizedKeys do
  @moduledoc """
  The server's `/home/ubuntu/.ssh/authorized_keys`, read into lines and written back, as
  `EhosPlatform.Server.Administrators` keeps it (eh-os D-199).

  Each `t:line/0` is one of:

    * `:named`, a key whose comment is `ehos-administrator:<name>:<id>`, the line of an
      installation administrator, or `ehos-administrator:shared`, the key every administrator
      shared before;
    * `:agent`, a key GCP's guest agent wrote, with the line `# Added by Google` before it, which
      is kept as it is, marker and all;
    * `:unnamed`, any other key, as cloud-init or a person wrote it;
    * `:unreadable`, a line that is neither blank nor a comment and holds no key that ehosctl
      reads, kept as it is, which `ehosctl server admin list` shows;
    * `:other`, a blank line or a comment, kept as it is.

  A line keeps its text, so that a file read and written back without a change is the same file.
  """

  @prefix "ehos-administrator"
  @shared "shared"
  @agent_marker "# Added by Google"

  @typedoc "A public key, by its type and its base64 blob, as OpenSSH compares them."
  @type key :: {type :: String.t(), blob :: String.t()}

  @typedoc "One line of the file, or two for a line of GCP's guest agent, and what it holds."
  @type line :: %{
          kind: :named | :agent | :unnamed | :unreadable | :other,
          text: String.t(),
          key: key() | nil,
          comment: String.t(),
          options: String.t() | nil,
          name: String.t() | nil,
          id: String.t() | nil
        }

  @doc "The name of the key every installation administrator shared before eh-os D-199."
  @spec shared() :: String.t()
  def shared, do: @shared

  @doc """
  The comment of an administrator's line: `ehos-administrator:<name>:<id>`, or
  `ehos-administrator:shared` for the shared key, which has no id.

      iex> EhosPlatform.Server.AuthorizedKeys.comment("ada", "1a2b3c4d")
      "ehos-administrator:ada:1a2b3c4d"

      iex> EhosPlatform.Server.AuthorizedKeys.comment("shared", nil)
      "ehos-administrator:shared"
  """
  @spec comment(String.t(), String.t() | nil) :: String.t()
  def comment(@shared, nil), do: "#{@prefix}:#{@shared}"
  def comment(name, id), do: "#{@prefix}:#{name}:#{id}"

  @doc """
  The name and id an `ehos-administrator:` user or comment holds, `nil` for the id of the shared
  key, or `:error` for anything else.

      iex> EhosPlatform.Server.AuthorizedKeys.named("ehos-administrator:ada:1a2b3c4d")
      {:ok, "ada", "1a2b3c4d"}

      iex> EhosPlatform.Server.AuthorizedKeys.named("ehos-administrator:shared")
      {:ok, "shared", nil}

      iex> EhosPlatform.Server.AuthorizedKeys.named("ehos-administrator:ada")
      :error
  """
  @spec named(String.t()) :: {:ok, String.t(), String.t() | nil} | :error
  def named(comment) do
    case Regex.run(~r/\Aehos-administrator:([a-z][a-z0-9-]{0,30})(?::([0-9a-f]{8}))?\z/, comment) do
      [_, @shared] -> {:ok, @shared, nil}
      [_, name, id] when name != @shared -> {:ok, name, id}
      _other -> :error
    end
  end

  @doc """
  The lines of `contents`, in order. A key with options before it, such as `from=`, is read by
  the type and blob after them.
  """
  @spec parse(String.t()) :: [line()]
  def parse(contents) do
    contents
    |> String.split("\n")
    |> drop_last_empty()
    |> lines([])
  end

  defp drop_last_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _text -> lines
    end
  end

  defp lines([], read), do: Enum.reverse(read)

  defp lines([marker, text | rest], read) when marker == @agent_marker do
    case key_line(text) do
      {key, comment, options} ->
        line = %{
          kind: :agent,
          text: marker <> "\n" <> text,
          key: key,
          comment: comment,
          options: options
        }

        lines(rest, [with_name(line) | read])

      nil ->
        lines([text | rest], [other(marker) | read])
    end
  end

  defp lines([text | rest], read) do
    line =
      case key_line(text) do
        {key, comment, options} ->
          key_kind(%{text: text, key: key, comment: comment, options: options})

        nil ->
          unread(text)
      end

    lines(rest, [line | read])
  end

  defp key_kind(line) do
    case named(line.comment) do
      {:ok, name, id} -> Map.merge(line, %{kind: :named, name: name, id: id})
      :error -> with_name(Map.put(line, :kind, :unnamed))
    end
  end

  defp with_name(line), do: Map.merge(line, %{name: nil, id: nil})

  # A line that is neither blank nor a comment, and holds no key ehosctl reads: sshd may read one.
  defp unread(text) do
    if Regex.match?(~r/\A[ \t]*(#|\z)/, text),
      do: other(text),
      else: %{other(text) | kind: :unreadable}
  end

  defp other(text),
    do: %{kind: :other, text: text, key: nil, comment: "", options: nil, name: nil, id: nil}

  # As sshd reads a line: a key type and its base64 blob, then the comment, with an options field
  # before them when the line does not start with a key type. The options field ends at the first
  # blank outside double quotes, where `\"` is a quote within them, so a key type quoted inside an
  # option, as in `command="… ssh-ed25519 …"`, is not read as the line's key. A `#` line is a
  # comment, whatever it holds.
  # sshd reads a line as a C string, to its first NUL, and its blanks are spaces and tabs alone.
  defp key_line(text) do
    [read | _after_nul] = :binary.split(text, <<0>>)
    read |> String.replace(~r/\A[ \t]+/, "") |> unblank_line()
  end

  # sshd skips the blanks before a line's first word, then reads `#` as a comment.
  defp unblank_line("#" <> _comment), do: nil

  defp unblank_line(trimmed) do
    case String.split(trimmed, ~r/[ \t]+/, parts: 2) do
      [first | _rest] when first != "" ->
        if key_type?(first), do: key_fields(trimmed, nil), else: optioned(trimmed)

      _blank ->
        nil
    end
  end

  defp optioned(text) do
    {options, rest} = options_field(text, "", false)
    key_fields(rest, options)
  end

  defp options_field(<<"\\\"", rest::binary>>, read, true),
    do: options_field(rest, read <> "\\\"", true)

  defp options_field(<<"\"", rest::binary>>, read, quoted?),
    do: options_field(rest, read <> "\"", not quoted?)

  defp options_field(<<blank, rest::binary>>, read, false) when blank in [?\s, ?\t],
    do: {read, rest}

  defp options_field(<<char::utf8, rest::binary>>, read, quoted?),
    do: options_field(rest, read <> <<char::utf8>>, quoted?)

  defp options_field(<<_byte, rest::binary>>, read, quoted?),
    do: options_field(rest, read, quoted?)

  defp options_field("", read, _quoted?), do: {read, ""}

  defp key_fields(text, options) do
    with [type, blob | comment] <- String.split(text, ~r/[ \t]+/, trim: true),
         true <- key_type?(type),
         {:ok, _decoded} <- Base.decode64(blob) do
      {{type, blob}, Enum.join(comment, " "), options}
    else
      _other -> nil
    end
  end

  defp key_type?(word), do: word =~ ~r/\A(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\z/

  @doc """
  The file that `lines` make, each line's text on a line of its own, ending with a newline.

      iex> alias EhosPlatform.Server.AuthorizedKeys
      iex> contents = "ssh-ed25519 AAAA ada\\n\\n# a comment\\n"
      iex> contents |> AuthorizedKeys.parse() |> AuthorizedKeys.render()
      "ssh-ed25519 AAAA ada\\n\\n# a comment\\n"
  """
  @spec render([line()]) :: String.t()
  def render([]), do: ""
  def render(lines), do: Enum.map_join(lines, "\n", & &1.text) <> "\n"

  @doc "The line ehosctl writes for `key` and the administrator `name` with `id`."
  @spec named_line(key(), String.t(), String.t() | nil) :: line()
  def named_line({type, blob} = key, name, id) do
    comment = comment(name, id)

    %{
      kind: :named,
      text: "#{type} #{blob} #{comment}",
      key: key,
      comment: comment,
      options: nil,
      name: name,
      id: id
    }
  end

  @doc """
  The one public key a file given to `ehosctl server admin add` holds: an `ssh-ed25519` or
  `ecdsa-sha2-nistp256` key, with no options before it and a comment or none after it.
  """
  @spec public_key(String.t()) :: {:ok, key()} | {:error, String.t()}
  def public_key(contents) do
    case contents |> String.split("\n", trim: true) |> Enum.reject(&(String.trim(&1) == "")) do
      [text] -> one_key(String.split(text))
      [] -> {:error, "The file holds no public key."}
      _many -> {:error, "The file holds more than one line. Give a file with one public key."}
    end
  end

  defp one_key([type, blob | _comment]) when type in ["ssh-ed25519", "ecdsa-sha2-nistp256"] do
    case Base.decode64(blob) do
      {:ok, decoded} ->
        if blob_type(decoded) == type,
          do: {:ok, {type, blob}},
          else: {:error, "The key in the file is not a #{type} key that OpenSSH reads."}

      :error ->
        {:error, "The key in the file is not base64."}
    end
  end

  defp one_key(_words),
    do:
      {:error,
       "The file does not start with an ssh-ed25519 or ecdsa-sha2-nistp256 public key. Give " <>
         "the .pub file of such a key, with no options such as from= or command= before it."}

  # The type a public key's blob names in its first field, as OpenSSH writes it.
  defp blob_type(<<length::32, type::binary-size(length), _rest::binary>>), do: type
  defp blob_type(_blob), do: nil

  @doc """
  The SHA-256 fingerprint of `key`, as `ssh-keygen -l` and sshd's log print it.

      iex> EhosPlatform.Server.AuthorizedKeys.fingerprint({"ssh-ed25519", "AAAA"})
      "SHA256:" <> Base.encode64(:crypto.hash(:sha256, <<0, 0, 0>>), padding: false)
  """
  @spec fingerprint(key()) :: String.t()
  def fingerprint({_type, blob}) do
    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, Base.decode64!(blob)), padding: false)
  end

  @doc """
  The key a public-key file or a variable holds, `<type> <blob> [comment]`, or `nil` when it holds
  none.

      iex> EhosPlatform.Server.AuthorizedKeys.key_of("ssh-ed25519 AAAA ada@laptop\\n")
      {"ssh-ed25519", "AAAA"}
  """
  @spec key_of(String.t() | nil) :: key() | nil
  def key_of(text) when is_binary(text) do
    case key_line(String.trim(text)) do
      {key, _comment, _options} -> key
      nil -> nil
    end
  end

  def key_of(nil), do: nil
end
