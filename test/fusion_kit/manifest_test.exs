defmodule FusionKit.ManifestTest do
  use ExUnit.Case, async: true

  defmodule NodeA do
    use FusionKit.Node
    definition do: %{name: "node_a", title: "Node A"}
    @impl true
    def handler(ctx, _), do: {:ok, ctx, "ok"}
  end

  defmodule NodeB do
    use FusionKit.Node
    definition do: %{name: "node_b", title: "Node B"}
    @impl true
    def handler(ctx, _), do: {:ok, ctx, "ok"}
  end

  defmodule TestManifest do
    use FusionKit.Manifest

    manifest do
      nodes [
        NodeA,
        NodeB
      ]
    end
  end

  test "manifest registers available_nodes/0" do
    assert TestManifest.available_nodes() == [NodeA, NodeB]
  end

  test "manifest gets definitions/0" do
    definitions = TestManifest.get_definitions()
    assert length(definitions) == 2

    node_a_def = Enum.find(definitions, &(&1.name == "node_a"))
    assert node_a_def.module == NodeA
    assert node_a_def.title == "Node A"
  end

  test "manifest gets node module by name" do
    assert TestManifest.get_node_module("node_a") == NodeA
    assert TestManifest.get_node_module("node_b") == NodeB
    assert TestManifest.get_node_module("unknown") == nil
  end
end
