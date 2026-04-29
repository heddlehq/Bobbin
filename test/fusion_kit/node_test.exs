defmodule FusionKit.NodeTest do
  use ExUnit.Case, async: true

  defmodule TestNode do
    use FusionKit.Node

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

  describe "to_rete/1" do
    test "converts node definition to Rete.js format" do
      rete = FusionKit.Node.to_rete(TestNode)

      assert rete.id == "test_node"
      assert rete.label == "Test Node"
      assert rete.category == :general
      assert rete.color == "bg-blue-500"
      assert rete.icon == "hero-cog"
    end

    test "converts atom ports to Rete.js socket maps" do
      rete = FusionKit.Node.to_rete(TestNode)

      assert rete.inputs == [%{id: "exec", label: "Exec"}]
      assert rete.outputs == [%{id: "success", label: "Success"}]
    end

    test "converts string ports" do
      defmodule StringPortNode do
        use FusionKit.Node
        definition do: %{name: "sp", title: "SP", inputs: ["my_input"], outputs: ["out"]}
        @impl true
        def handler(ctx, _), do: {:ok, ctx, "out"}
      end

      rete = FusionKit.Node.to_rete(StringPortNode)

      assert rete.inputs == [%{id: "my_input", label: "my_input"}]
      assert rete.outputs == [%{id: "out", label: "out"}]
    end

    test "converts map ports as-is" do
      defmodule MapPortNode do
        use FusionKit.Node

        definition do
          %{
            name: "mp",
            title: "MP",
            inputs: [%{id: "data", label: "Data In", socket: "json"}],
            outputs: []
          }
        end

        @impl true
        def handler(ctx, _), do: {:ok, ctx, :ok}
      end

      rete = FusionKit.Node.to_rete(MapPortNode)

      assert rete.inputs == [%{id: "data", label: "Data In", socket: "json"}]
      assert rete.outputs == []
    end

    test "omits optional fields when not present" do
      defmodule MinimalNode do
        use FusionKit.Node
        definition do: %{name: "min", title: "Min"}
        @impl true
        def handler(ctx, _), do: {:ok, ctx, :ok}
      end

      rete = FusionKit.Node.to_rete(MinimalNode)

      assert rete.id == "min"
      assert rete.label == "Min"
      assert rete.inputs == []
      assert rete.outputs == []
      refute Map.has_key?(rete, :category)
      refute Map.has_key?(rete, :color)
      refute Map.has_key?(rete, :icon)
    end
  end
end
