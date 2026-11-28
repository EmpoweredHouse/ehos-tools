defmodule EhosRelease.VersionFile do
  @moduledoc """
  A file that carries a component's version on one whole line, as `EhosRelease.Config` names it:
  `{version}` in the line stands for the version. A release replaces that one line, and refuses a
  file where the line is not found exactly once (T-34).
  """

  @doc """
  The file's text with the version in its line, or a refusal.

      iex> EhosRelease.VersionFile.replace("x\\n  @version \\"0.1.0\\"\\n", ~s(  @version "{version}"), "0.2.0")
      {:ok, "x\\n  @version \\"0.2.0\\"\\n"}

      iex> EhosRelease.VersionFile.replace("version: 1.0.0\\nappVersion: 1.0.0\\n", "version: {version}", "1.1.0")
      {:ok, "version: 1.1.0\\nappVersion: 1.0.0\\n"}

      iex> EhosRelease.VersionFile.replace("nothing\\n", "version: {version}", "1.1.0")
      {:error, "the line `version: {version}` is found 0 times, not once"}
  """
  @spec replace(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def replace(contents, line, version) do
    regex = regex(line)

    case Regex.scan(regex, contents) do
      [_one] ->
        {:ok,
         Regex.replace(regex, contents, fn _ -> String.replace(line, "{version}", version) end,
           global: false
         )}

      found ->
        {:error, "the line `#{line}` is found #{length(found)} times, not once"}
    end
  end

  @doc """
  The version the file's line holds, when the line is found exactly once.

      iex> EhosRelease.VersionFile.version("version: 1.0.0\\n", "version: {version}")
      {:ok, "1.0.0"}
  """
  @spec version(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def version(contents, line) do
    case Regex.scan(regex(line), contents, capture: :all_but_first) do
      [[version]] -> {:ok, version}
      found -> {:error, "the line `#{line}` is found #{length(found)} times, not once"}
    end
  end

  @doc """
  Whether `text` is the file's line with `version` in it, as a release's change has it.
  """
  @spec line?(String.t(), String.t(), String.t()) :: boolean()
  def line?(text, line, version), do: text == String.replace(line, "{version}", version)

  defp regex(line) do
    [before, after_version] = String.split(line, "{version}")

    Regex.compile!(
      "^" <>
        Regex.escape(before) <>
        "(\\d+\\.\\d+\\.\\d+[0-9A-Za-z.+-]*)" <> Regex.escape(after_version) <> "$",
      "m"
    )
  end
end
