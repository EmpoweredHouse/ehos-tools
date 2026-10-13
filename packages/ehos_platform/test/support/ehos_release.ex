defmodule Ehos.Release do
  @moduledoc false

  # A stand-in for eh-os's `Ehos.Release`, whose `invite/1` the expression that
  # `EhosPlatform.Install.invite_expression/1` writes calls. It tells the process that evaluates
  # the expression what it was given, so a test shows that evaluating it makes that call, with
  # that address, and nothing else.
  def invite(email) do
    send(self(), {:invited, email})
    :ok
  end
end
