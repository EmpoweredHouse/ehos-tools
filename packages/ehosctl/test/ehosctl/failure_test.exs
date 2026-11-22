defmodule Ehosctl.FailureTest do
  use Ehosctl.Case, async: true

  alias Ehosctl.Failure

  describe "sentence/1" do
    test "leaves out a command that a shell would expand once printed, and advice that introduced it" do
      command = "ehosctl env remove 'x$(id)'\\''\e'"

      assert Failure.sentence(Failure.new("It failed.", to_do: [command])) == "It failed."

      assert Failure.sentence(
               Failure.new("It failed.", advice: "To keep them, run:", to_do: [command])
             ) == "It failed."

      assert Failure.sentence(
               Failure.new("It failed.", advice: "Open the console.", to_do: [command])
             ) == "It failed. Open the console."
    end
  end
end
