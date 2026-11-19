defmodule Ehosctl.Failure do
  @moduledoc """
  An error's message in the shape
  [T-28](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0028-ehosctl-says-everything-in-a-few-shared-shapes-built-as-tagged-data-and-colours-them-only-on-a-terminal-without-no-color.md)
  gives it: what failed, then what to do, apart, so that `Ehosctl.Output.error/4` prints what to
  do under its own `What to do:` and each command on a line of its own, ready to copy.

  `said` is what failed, with what the command adds on its way out (`added/2`). `tool_output` is
  what another program printed when it failed, each with the name of the program, shown under
  that name after what failed. `advice` is a sentence of what to do that is no command, which ends
  in a colon when commands follow it, and `to_do` the commands that put it right, each with the
  `--installation` it talks to. A message that says nothing to do and holds no program's output
  stays a string: both are `t:message/0`, and a function that takes a message takes both.

  As a string, by `to_string/1` or in an interpolation, it is what failed, what each program
  printed on the lines after it, and then each command in a sentence of its own: what `--json`
  prints as the message, and what another message quotes.

      iex> failure = Ehosctl.Failure.new("You are not signed in to office.",
      ...>   to_do: ["ehosctl login --installation office"])
      iex> to_string(failure)
      "You are not signed in to office. Run `ehosctl login --installation office`."
  """

  @enforce_keys [:said]
  defstruct said: "", tool_output: [], advice: nil, to_do: []

  @type t :: %__MODULE__{
          said: String.t(),
          tool_output: [{String.t(), String.t()}],
          advice: String.t() | nil,
          to_do: [String.t()]
        }

  @typedoc "An error's message: a string when it says nothing to do, else a `t:t/0`."
  @type message :: String.t() | t()

  @doc """
  What failed, `said`, with what each program printed, `:tool_output`, the `:advice` and the
  commands `:to_do` of `opts`.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(said, opts \\ []) when is_binary(said),
    do: %__MODULE__{
      said: said,
      tool_output: Keyword.get(opts, :tool_output, []),
      advice: opts[:advice],
      to_do: Keyword.get(opts, :to_do, [])
    }

  @doc """
  `message` with `more` added to what failed, before what to do.

      iex> Ehosctl.Failure.added("It failed.", " Nothing was sent.")
      "It failed. Nothing was sent."

      iex> Ehosctl.Failure.new("It failed.", to_do: ["ehosctl login"])
      ...> |> Ehosctl.Failure.added(" Nothing was sent.")
      ...> |> to_string()
      "It failed. Nothing was sent. Run `ehosctl login`."
  """
  @spec added(message(), String.t()) :: message()
  def added(message, more) when is_binary(message), do: message <> more
  def added(%__MODULE__{} = failure, more), do: %{failure | said: failure.said <> more}

  @doc """
  `message` with `advice` and `commands` as what to do, in place of what it said to do: a string
  becomes a `t:t/0`.

      iex> Ehosctl.Failure.with_to_do("EHOS possibly made the change.", "See whether it did:",
      ...>   ["ehosctl env show --installation office"])
      %Ehosctl.Failure{said: "EHOS possibly made the change.", advice: "See whether it did:",
        to_do: ["ehosctl env show --installation office"]}
  """
  @spec with_to_do(message(), String.t() | nil, [String.t()]) :: t()
  def with_to_do(message, advice, commands) when is_binary(message),
    do: new(message, advice: advice, to_do: commands)

  def with_to_do(%__MODULE__{} = failure, advice, commands),
    do: %{failure | advice: advice, to_do: commands}

  @doc """
  What failed, without what to do: for a message quoted where its advice does not hold, as when
  a sign-out that already happened on this computer quotes why EHOS did not receive it.

      iex> Ehosctl.Failure.new("It did not answer.", advice: "Run the command again.")
      ...> |> Ehosctl.Failure.said()
      "It did not answer."
  """
  @spec said(message()) :: String.t()
  def said(message) when is_binary(message), do: message
  def said(%__MODULE__{said: said}), do: said

  @doc "`message` as one paragraph, as `to_string/1` gives a `t:t/0`."
  @spec sentence(message()) :: String.t()
  def sentence(message) when is_binary(message), do: message

  def sentence(%__MODULE__{} = failure) do
    printed = for {_tool, text} <- failure.tool_output, do: String.trim_trailing(text)

    Enum.join(
      [
        Enum.join([failure.said | printed], "\n") | to_do_sentences(failure.advice, failure.to_do)
      ],
      " "
    )
  end

  defp to_do_sentences(nil, commands), do: Enum.map(commands, &"Run `#{&1}`.")
  defp to_do_sentences(advice, []), do: [advice]

  defp to_do_sentences(advice, commands),
    do: [advice <> " " <> Enum.map_join(commands, ", or ", &"`#{&1}`") <> "."]

  defimpl String.Chars do
    def to_string(failure), do: Ehosctl.Failure.sentence(failure)
  end

  # A message a report keeps, as `ehosctl versions` keeps what GitHub did not answer, is the
  # paragraph in JSON too.
  defimpl JSON.Encoder do
    def encode(failure, encoder), do: encoder.(Ehosctl.Failure.sentence(failure), encoder)
  end
end
