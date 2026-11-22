defmodule EhosPlatform.ShellTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Shell

  doctest EhosPlatform.Shell

  describe "pattern/1" do
    # The wedged tunnel's test in `EhosPlatform.ServerTest` escapes its own directory with this
    # function, a path it cannot know ahead; what that escaping must be is pinned here, written out
    # (ehos-tools#571).
    test "escapes with a backslash each character an extended regular expression reads" do
      assert Shell.pattern(~S"/a\b.c[d]e(f)g*h+i?j{k}l|m^n$o") ==
               ~S"/a\\b\.c\[d\]e\(f\)g\*h\+i\?j\{k\}l\|m\^n\$o"
    end

    test "leaves a path with no such character as it is" do
      assert Shell.pattern("/Users/Jane O'Brien-work/~trial,1/tunnel_sock") ==
               "/Users/Jane O'Brien-work/~trial,1/tunnel_sock"
    end
  end

  describe "word/1" do
    test "quotes a value that starts with a dash, which a program reads as an option" do
      assert Enum.map(["-", "-rf", "--yes", "a-b"], &Shell.word/1) ==
               ["'-'", "'-rf'", "'--yes'", "a-b"]
    end
  end

  describe "pastable?/1" do
    test "takes a command whose values word/1 quoted, with what a shell expands and a quote in them" do
      values = ["x$(id)", "it's", "a b", "`id`", "ledger", ""]

      for value <- values do
        assert Shell.pastable?("ehosctl env remove #{Shell.word(value)} --installation office")
      end
    end

    test "takes the command's own options, double quotes and escapes that hold no backslash" do
      assert Shell.pastable?(~S|ehosctl promote ledger --break "billing moves" --json|)
      assert Shell.pastable?(~S{echo it\'s "a \"b\"" | sh -s})
    end

    test "refuses a value from word/1 that starts with a dash, whatever follows it" do
      for value <- ["--yes", "--installation=other", "-rf", "-"] do
        refute Shell.pastable?("ehosctl env remove #{Shell.word(value)} --installation office")
      end
    end

    test "refuses a value with a backslash, which fish reads inside single quotes" do
      for value <- [~S{\';id;\'}, ~S{a\b}, "\\"] do
        refute Shell.pastable?("ehosctl env remove #{Shell.word(value)} --installation office")
      end

      refute Shell.pastable?(~S|ehosctl x "a\\b"|)
      refute Shell.pastable?(~S|ehosctl x a\\b|)
    end

    test "refuses a quote left open and a character a terminal acts on" do
      refute Shell.pastable?("ehosctl env remove 'ledger --installation office")
      refute Shell.pastable?(~S|ehosctl env remove "ledger|)
      refute Shell.pastable?("ehosctl env remove #{Shell.word("x\e[2J")}")
      refute Shell.pastable?(<<"ehosctl ", 0xFF>>)
    end
  end
end
