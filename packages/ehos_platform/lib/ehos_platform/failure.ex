defmodule EhosPlatform.Failure do
  @moduledoc """
  An error that holds what another program printed, apart from this package's own words
  (ehos-tools T-28), so that its caller shows that output under the name of the program.

  `said` is what failed, in sentences, with what a caller adds on its way out (`added/2`).
  `tool_output` is what each program printed, with its name, in the order they ran. An error with
  no program's output stays a string: both are `t:message/0`, and a function that takes a message
  takes both.

  As a string, by `to_string/1` or in an interpolation, it is `said` and then each output on the
  lines after it: what a log, or another message that quotes it, holds.

      iex> failure = EhosPlatform.Failure.new("`kubectl` failed with exit status 1.",
      ...>   "kubectl", "error: the server doesn't have a resource type")
      iex> to_string(failure)
      "`kubectl` failed with exit status 1.\\nerror: the server doesn't have a resource type"
  """

  @enforce_keys [:said]
  defstruct said: "", tool_output: []

  @type t :: %__MODULE__{said: String.t(), tool_output: [{String.t(), String.t()}]}

  @typedoc "An error's message: a string when no program's output is in it, else a `t:t/0`."
  @type message :: String.t() | t()

  @doc "What failed, `said`, with what `tool` printed, `printed`."
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(said, tool, printed) when is_binary(said) and is_binary(tool) and is_binary(printed),
    do: %__MODULE__{said: said, tool_output: [{tool, printed}]}

  @doc """
  The error of `program`, which ended with exit status `status` after it printed `printed`: a
  `t:t/0` with what it printed, or a sentence alone when it printed nothing.

      iex> EhosPlatform.Failure.exited("helm", 1, "Error: timed out\\n")
      %EhosPlatform.Failure{said: "`helm` failed with exit status 1.",
        tool_output: [{"helm", "Error: timed out\\n"}]}

      iex> EhosPlatform.Failure.exited("helm", 1, "  \\n")
      "`helm` failed with exit status 1."
  """
  @spec exited(String.t(), integer(), String.t()) :: message()
  def exited(program, status, printed),
    do: printed("`#{program}` failed with exit status #{status}.", program, printed)

  @doc """
  `said`, with what `program` printed, `printed`, unless it printed nothing but white space.
  """
  @spec printed(String.t(), String.t(), String.t()) :: message()
  def printed(said, program, printed) do
    if String.trim(printed) == "", do: said, else: new(said, program, printed)
  end

  @doc """
  `message` with `more` added to what failed: after a string, and after `said` of a `t:t/0`,
  before what the program printed.

      iex> EhosPlatform.Failure.added("It failed.", " Nothing was changed.")
      "It failed. Nothing was changed."

      iex> EhosPlatform.Failure.new("`helm` failed.", "helm", "Error: timed out")
      ...> |> EhosPlatform.Failure.added(" Is the tunnel open?")
      ...> |> to_string()
      "`helm` failed. Is the tunnel open?\\nError: timed out"
  """
  @spec added(message(), String.t()) :: message()
  def added(message, more) when is_binary(message), do: message <> more
  def added(%__MODULE__{} = failure, more), do: %{failure | said: failure.said <> more}

  @doc """
  `message` inside the sentence `before` and `following` make: around a string, and around `said` of
  a `t:t/0`, whose program's output stays apart.

      iex> EhosPlatform.Failure.new("`kubectl` failed.", "kubectl", "Forbidden")
      ...> |> EhosPlatform.Failure.within("It did not restart: ", " Run it again.")
      ...> |> to_string()
      "It did not restart: `kubectl` failed. Run it again.\\nForbidden"
  """
  @spec within(message(), String.t(), String.t()) :: message()
  def within(message, before, following) when is_binary(message),
    do: before <> message <> following

  def within(%__MODULE__{} = failure, before, following),
    do: %{failure | said: before <> failure.said <> following}

  @doc """
  `first` and then `second`, after `between`: one sentence, and what each program printed, those
  of `first` before those of `second`.

      iex> EhosPlatform.Failure.new("`tofu apply` failed.", "tofu apply", "Error: VPC")
      ...> |> EhosPlatform.Failure.joined(" Also: ",
      ...>   EhosPlatform.Failure.new("`tofu output` failed.", "tofu output", "Error: lock"))
      %EhosPlatform.Failure{said: "`tofu apply` failed. Also: `tofu output` failed.",
        tool_output: [{"tofu apply", "Error: VPC"}, {"tofu output", "Error: lock"}]}

      iex> EhosPlatform.Failure.joined("It failed.", " Also: ", "it stopped.")
      "It failed. Also: it stopped."
  """
  @spec joined(message(), String.t(), message()) :: message()
  def joined(first, between, second) when is_binary(first) and is_binary(second),
    do: first <> between <> second

  def joined(first, between, second),
    do: %__MODULE__{
      said: said(first) <> between <> said(second),
      tool_output: outputs(first) ++ outputs(second)
    }

  defp said(message) when is_binary(message), do: message
  defp said(%__MODULE__{said: said}), do: said

  defp outputs(message) when is_binary(message), do: []
  defp outputs(%__MODULE__{tool_output: tool_output}), do: tool_output

  @doc """
  What `message` says, and what each program printed, apart: for a step or a warning that says
  the sentence and gives each output as `{:tool_output, tool, printed}` after it.

      iex> EhosPlatform.Failure.parts(EhosPlatform.Failure.new("It failed.", "kubectl", "Error"))
      {"It failed.", [{"kubectl", "Error"}]}

      iex> EhosPlatform.Failure.parts("It failed.")
      {"It failed.", []}
  """
  @spec parts(message()) :: {String.t(), [{String.t(), String.t()}]}
  def parts(message) when is_binary(message), do: {message, []}
  def parts(%__MODULE__{said: said, tool_output: tool_output}), do: {said, tool_output}

  @doc """
  `message` with `fun` applied to each of its strings: what failed and what each program printed,
  as when a credential is taken out of all of them.
  """
  @spec map_text(message(), (String.t() -> String.t())) :: message()
  def map_text(message, fun) when is_binary(message), do: fun.(message)

  def map_text(%__MODULE__{} = failure, fun),
    do: %{
      failure
      | said: fun.(failure.said),
        tool_output: for({tool, printed} <- failure.tool_output, do: {tool, fun.(printed)})
    }

  defimpl String.Chars do
    def to_string(failure),
      do:
        Enum.join(
          [failure.said | for({_tool, printed} <- failure.tool_output, do: printed)],
          "\n"
        )
  end
end
