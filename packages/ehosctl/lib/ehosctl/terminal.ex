defmodule Ehosctl.Terminal do
  @moduledoc """
  What a person types, and whether they are at a terminal, as a way out (T-20): a question's
  answer, a value on standard input, whether a prompt would be seen. What ehosctl prints is not
  here: it is written with `IO`, and a test reads it with `ExUnit.CaptureIO`. `Ehosctl.Case`
  gives every test no terminal and nothing typed, unless it says otherwise.
  """

  @doc "Writes `prompt` and reads one line of the answer, or `nil` when input has ended."
  @callback gets(prompt :: String.t()) :: String.t() | nil

  @doc """
  Reads standard input as bytes, `count` of them at most or all of it with `:eof`, whatever the
  locale: `:eof` when it has ended, `{:error, reason}` when it cannot be read.
  """
  @callback read_input(count :: pos_integer() | :eof) :: binary() | :eof | {:error, term()}

  @doc "Whether standard input is a terminal."
  @callback input_terminal?() :: boolean()

  @doc "Whether standard error is a terminal."
  @callback error_terminal?() :: boolean()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.TerminalImpl do
  @moduledoc "The `Ehosctl.Terminal` of this process's standard input and error."

  @behaviour Ehosctl.Terminal

  @impl true
  def gets(prompt) do
    case IO.gets(:stdio, prompt) do
      answer when is_binary(answer) -> answer
      _eof -> nil
    end
  end

  # Standard input is in unicode mode (`Ehosctl.Application`), which would turn a byte that is not
  # UTF-8 into a character, so it is read in latin1, which hands each byte on as it came. It is
  # standard output's device too, so its encoding is put back, or what is printed next would be
  # written in latin1.
  @impl true
  def read_input(count) do
    encoding =
      case :io.getopts(:standard_io) do
        options when is_list(options) -> Keyword.get(options, :encoding)
        _error -> nil
      end

    _ = :io.setopts(:standard_io, encoding: :latin1)

    try do
      IO.binread(:stdio, count)
    after
      if encoding, do: :io.setopts(:standard_io, encoding: encoding)
    end
  end

  @impl true
  def input_terminal?, do: terminal?(:stdin)

  @impl true
  def error_terminal?, do: terminal?(:stderr)

  # `:standard_error`'s own options say it is no terminal even on one; `:standard_io`'s say
  # which of the three streams are.
  defp terminal?(stream) do
    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, stream) == true
      _error -> false
    end
  end
end
