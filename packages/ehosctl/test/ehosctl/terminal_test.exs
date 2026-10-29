defmodule Ehosctl.TerminalTest do
  use Ehosctl.Case, async: true
  use Hammox.Protect, module: Ehosctl.TerminalImpl, behaviour: Ehosctl.Terminal

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "asks, and reads the line answered, or nothing once input has ended" do
    output = capture_io("yes\n", fn -> assert gets("Remove it? ") == "yes\n" end)
    assert output == "Remove it? "

    capture_io("", fn -> assert gets("Remove it? ") == nil end)
  end

  # Standard input in Unicode mode, as under a UTF-8 locale, and in latin1: the bytes come as they
  # came, and the device's own encoding is put back, since standard output shares it.
  test "reads standard input as the bytes that came, whatever its encoding", %{tmp_dir: dir} do
    file = Path.join(dir, "value")
    File.write!(file, "zażółć €\n")

    for mode <- [:utf8, :binary] do
      {:ok, device} = File.open(file, [:read, mode])

      read =
        Task.async(fn ->
          Process.group_leader(self(), device)
          {read_input(100), read_input(1), :io.getopts(:standard_io)[:encoding]}
        end)

      assert Task.await(read) ==
               {"zażółć €\n", :eof, if(mode == :utf8, do: :unicode, else: :latin1)}

      File.close(device)
    end
  end

  test "says whether standard input and error are a terminal" do
    assert is_boolean(input_terminal?())
    assert is_boolean(error_terminal?())
  end
end
