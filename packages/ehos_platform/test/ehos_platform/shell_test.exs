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
end
