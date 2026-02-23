defmodule FusionKit.NodeTest do
  use ExUnit.Case, async: true

  defmodule TestNode do
    use FusionKit.Node

    definition do
      %{
        name: "test_node",
        title: "Test Node",
        inputs: [:exec],
        outputs: [:success]
      }
    end

    @impl true
    def handler(_config, context, _input) do
      {:ok, context, :success}
    end
  end

  test "node defines definition/0" do
    assert TestNode.definition().name == "test_node"
    assert TestNode.definition().title == "Test Node"
    assert TestNode.definition().inputs == [:exec]
  end

  test "node implements handler/3" do
    assert {:ok, %{foo: "bar"}, :success} == TestNode.handler(%{}, %{foo: "bar"}, nil)
  end
end
