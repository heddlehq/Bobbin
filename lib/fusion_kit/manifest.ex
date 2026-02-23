defmodule FusionFlow.Manifest do
  @moduledoc """
  Macros and functions to define an integration manifest.

  The manifest acts as the registry for all nodes provided by an integration.

  ## Example

      defmodule MyIntegration do
        use FusionFlow.Manifest

        manifest do
          nodes [
            MyNodes.HttpNode,
            MyNodes.JsonParseNode
          ]
        end
      end

  Using the manifest macro automatically generates `available_nodes/0`, `get_definitions/0`,
  and `get_node_module/1`.
  """

  defmacro __using__(_opts) do
    quote do
      import FusionFlow.Manifest, only: [manifest: 1, nodes: 1]
    end
  end

  @doc """
  Block to define the integration manifest content.
  """
  defmacro manifest(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Registers a list of node modules and generates lookup functions.

  Generates:
  - `available_nodes/0`: Returns the list of modules.
  - `get_definitions/0`: Returns a list of all node definitions.
  - `get_node_module/1`: Finds a module by its node name.
  """
  defmacro nodes(module_list) do
    quote do
      @doc """
      Returns the list of modules registered in this manifest.
      """
      @spec available_nodes() :: [module()]
      def available_nodes do
        unquote(module_list)
      end

      @doc """
      Returns the definitions for all registered nodes, including the module reference.
      """
      @spec get_definitions() :: [map()]
      def get_definitions do
        available_nodes()
        |> Enum.map(fn module ->
          module.definition() |> Map.put(:module, module)
        end)
      end

      @doc """
      Finds the node module that defines a node with the given name.
      """
      @spec get_node_module(String.t()) :: module() | nil
      def get_node_module(name) do
        available_nodes()
        |> Enum.find(fn mod -> mod.definition().name == name end)
      end
    end
  end
end
