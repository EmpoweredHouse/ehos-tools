defmodule EhosRelease.DocTest do
  # The examples in the modules' docs are tests too.
  use ExUnit.Case, async: true

  doctest EhosRelease.Pin
  doctest EhosRelease.Producers
  doctest EhosRelease.MixLock
  doctest EhosRelease.Config
  doctest EhosRelease.GitImpl
  doctest EhosRelease.PinCheck
  doctest EhosRelease.Pins
  doctest EhosRelease.ChangieConfig
  doctest EhosRelease.Fragment
  doctest EhosRelease.Version
  doctest EhosRelease.VersionFile
  doctest EhosRelease.Description
end
