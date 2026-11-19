defmodule Ehosctl.PlatformReport do
  @moduledoc """
  Gives what `ehos_platform` says the shapes of
  [T-28](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0028-ehosctl-says-everything-in-a-few-shared-shapes-built-as-tagged-data-and-colours-them-only-on-a-terminal-without-no-color.md):
  an `EhosPlatform.Report` becomes an outcome, its values, what another program printed and the
  next commands, and each `t:EhosPlatform.Report.event/0` of a long command a line on stderr.
  """

  alias Ehosctl.Output
  alias EhosPlatform.Report

  @minute 60_000

  @doc """
  `report` as a command's text: the outcome, its values under it, what another program printed,
  and the commands to run next, each part after an empty line.

      iex> %EhosPlatform.Report{
      ...>   outcome: "The server ehos-office is up, with k3s.",
      ...>   values: [{"Address", "203.0.113.10"}],
      ...>   next: ["ehosctl server tunnel --installation office"]
      ...> }
      ...> |> Ehosctl.PlatformReport.text()
      ...> |> Ehosctl.Output.render(false)
      ...> |> IO.chardata_to_string()
      "✓ The server ehos-office is up, with k3s.\\n  Address   203.0.113.10\\n\\nNext:\\n  ehosctl server tunnel --installation office"
  """
  @spec text(Report.t()) :: Output.text()
  def text(%Report{} = report) do
    Output.lines(
      [
        Output.outcome(report.ending, report.outcome),
        if(report.values != [], do: Output.values(report.values))
      ] ++
        Enum.flat_map(report.tool_output, fn {tool, printed} ->
          ["", Output.tool_output(tool, printed)]
        end) ++
        if(report.next != [], do: ["", Output.next(report.next)], else: [])
    )
  end

  @doc """
  Prints `event` on stderr: a step and a wait as progress, a warning in its own shape, and what
  another program printed under its name. A wait is said when it begins, and then with how
  long it has lasted, as often as `ehos_platform` says it: once a minute.
  """
  @spec progress(Report.event()) :: :ok
  def progress({:step, text}), do: Output.progress(text)
  def progress({:waiting, text, 0}), do: Output.progress(text)

  def progress({:waiting, _text, elapsed}),
    do: Output.progress("The wait has lasted #{minutes(div(elapsed, @minute))}")

  def progress({:warning, head, explanation}), do: Output.warn(head, explanation)
  def progress({:tool_output, tool, printed}), do: Output.aside(Output.tool_output(tool, printed))

  defp minutes(1), do: "1 minute"
  defp minutes(count), do: "#{count} minutes"
end
