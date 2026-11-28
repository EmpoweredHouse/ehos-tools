defmodule EhosRelease.Task do
  @moduledoc false

  # What every task does with its refusals: prints each, and exits with 1.
  @spec refuse([String.t()]) :: no_return()
  def refuse(refusals) do
    Enum.each(refusals, fn refusal -> Mix.shell().error(refusal) end)
    Mix.raise("#{length(refusals)} refused", exit_status: 1)
  end
end
