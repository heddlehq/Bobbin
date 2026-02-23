defmodule FusionKitTest do
  use ExUnit.Case
  doctest FusionKit

  test "greets the world" do
    assert FusionKit.hello() == :world
  end
end
