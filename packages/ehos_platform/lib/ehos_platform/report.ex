defmodule EhosPlatform.Report do
  @moduledoc """
  What a command of this package says, as parts and not as a finished sentence (ehos-tools T-28),
  so that its caller gives each part the shape it prints: `ehosctl` puts the outcome after a
  marker, aligns the values, and puts each next command on a line of its own.

  A `t:t/0` is what a command did: `outcome`, one short sentence; `ending`, `:done`, or
  `:unchanged` when there was nothing to do; `values`, the labels and values a person looks for,
  in order; `next`, the commands to run next, each ready to copy; and `tool_output`, what another
  program printed, each with the name of that program, kept apart from this package's own words.

  A `t:event/0` is what a long command says while it runs, given to the caller's `:progress`
  function:

    * `{:step, text}`: a step starts;
    * `{:waiting, text, elapsed}`: the command still waits, `elapsed` milliseconds after it
      started to, so the caller can show a sign of life without a line for each attempt;
    * `{:warning, head, explanation}`: something the operator must know, which does not stop
      the command, `explanation` `nil` when the head says it all;
    * `{:tool_output, tool, text}`: what another program printed while the command ran.
  """

  @enforce_keys [:outcome]
  defstruct outcome: "", ending: :done, values: [], next: [], tool_output: []

  @type t :: %__MODULE__{
          outcome: String.t(),
          ending: :done | :unchanged,
          values: [{String.t(), String.t()}],
          next: [String.t()],
          tool_output: [{String.t(), String.t()}]
        }

  @type event ::
          {:step, String.t()}
          | {:waiting, String.t(), non_neg_integer()}
          | {:warning, String.t(), String.t() | nil}
          | {:tool_output, String.t(), String.t()}
end
