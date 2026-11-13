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

  # Whether they are depends on how the suite is run, so only the kind of answer is known.
  test "says whether standard input and error are a terminal" do
    assert is_boolean(input_terminal?())
    assert is_boolean(error_terminal?())
  end

  describe "the y/N question" do
    test "at a terminal, asks on standard error and takes y or yes, in any case, as a yes" do
      mock_terminals()

      for {typed, confirmed} <- [{"y\n", true}, {" YES \n", true}, {"no\n", false}, {"\n", false}] do
        expect(Ehosctl.TerminalMock, :gets, fn "" -> typed end)

        assert capture_io(:stderr, fn ->
                 assert Ehosctl.Terminal.confirm_at_terminal("Remove it?") == confirmed
               end) == "Remove it? [y/N] "
      end
    end

    test "at a terminal, takes input that has ended as a no" do
      mock_terminals()
      expect(Ehosctl.TerminalMock, :gets, fn "" -> nil end)

      assert capture_io(:stderr, fn ->
               assert Ehosctl.Terminal.confirm_at_terminal("Remove it?") == false
             end) == "Remove it? [y/N] "
    end

    test "where nobody can answer, does not ask" do
      for {input?, error?} <- [{false, true}, {true, false}, {false, false}] do
        stub(Ehosctl.TerminalMock, :input_terminal?, fn -> input? end)
        stub(Ehosctl.TerminalMock, :error_terminal?, fn -> error? end)

        assert capture_io(:stderr, fn ->
                 assert Ehosctl.Terminal.confirm_at_terminal("Remove it?") == nil
               end) == ""
      end
    end

    test "from any input, asks with the prompt and takes y or yes as a yes, anything else as a no" do
      for {typed, confirmed} <- [{"y\n", true}, {"Yes\n", true}, {"n\n", false}, {nil, false}] do
        expect(Ehosctl.TerminalMock, :gets, fn "Upgrade? [y/N] " -> typed end)

        assert Ehosctl.Terminal.confirm("Upgrade?") == confirmed
      end
    end
  end

  defp mock_terminals do
    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)
  end
end
