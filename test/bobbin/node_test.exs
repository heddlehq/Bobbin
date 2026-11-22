defmodule Bobbin.NodeTest do
  use ExUnit.Case, async: true

  defmodule TestNode do
    use Bobbin.Node

    definition do
      %{
        name: "test_node",
        title: "Test Node",
        category: :general,
        color: "bg-blue-500",
        icon: "hero-cog",
        inputs: [:exec],
        outputs: [:success]
      }
    end

    @impl true
    def handler(context, _input) do
      {:ok, context, :success}
    end
  end

  test "node defines definition/0" do
    assert TestNode.definition().name == "test_node"
    assert TestNode.definition().title == "Test Node"
    assert TestNode.definition().inputs == [:exec]
  end

  test "node implements handler/2" do
    assert {:ok, %{foo: "bar"}, :success} == TestNode.handler(%{foo: "bar"}, nil)
  end
end
