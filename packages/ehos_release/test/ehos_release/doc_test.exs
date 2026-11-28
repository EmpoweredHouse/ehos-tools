defmodule EhosRelease.DocTest do
  # The examples in the modules' docs are tests too.
  use ExUnit.Case, async: true

  doctest EhosRelease.Pin
  doctest EhosRelease.Producers
  doctest EhosRelease.MixLock
  doctest EhosRelease.Config
  doctest EhosRelease.GitImpl
  doctest EhosRelease.PinCheck
end
