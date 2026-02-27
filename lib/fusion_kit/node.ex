defmodule FusionKit.Node do
  @moduledoc """
  Defines the behavior and macros for creating FusionKit nodes.

  A node is the fundamental unit of logic in a flow. It consists of a `definition/0`
  describing its interface and a `handler/2` to process data.

  ## Example

      defmodule MyNodes.HttpNode do
        use FusionKit.Node

        definition do
          %{
            name: "http_request",
            title: "HTTP Request",
            category: :network,
            icon: "hero-globe-alt",
            inputs: [:exec, :url],
            outputs: [:success, :error]
          }
        end

        @impl true
        def handler(context, input) do
          {:ok, context, :success}
        end
      end
  """

  @type context :: map()
  @type input :: any()
  @type output_port :: atom() | String.t()
  @type node_definition :: %{
          required(:name) => String.t(),
          required(:title) => String.t(),
          optional(:category) => atom() | String.t(),
          optional(:icon) => String.t(),
          optional(:inputs) => [map() | atom() | String.t()],
          optional(:outputs) => [map() | atom() | String.t()],
          optional(atom()) => any()
        }

  @doc """
  Returns the metadata and interface definition for the node.
  """
  @callback definition() :: node_definition()

  @doc """
  Processes the node logic.

  Returns `{:ok, new_context, output_port}` on success, or `{:error, reason}` on failure.
  """
  @callback handler(context(), input()) ::
              {:ok, context(), output_port()}
              | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour FusionKit.Node
      import FusionKit.Node, only: [definition: 1]
    end
  end

  @doc """
  Macro to define the node metadata.
  """
  defmacro definition(do: block) do
    quote do
      @impl FusionKit.Node
      def definition do
        unquote(block)
      end
    end
  end

  @doc """
  Converts a node module's definition to a Rete.js-compatible map.

  The returned map follows the Rete.js node schema with `id`, `label`,
  `inputs`, and `outputs` structured as socket definitions.

  ## Example

      FusionKit.Node.to_rete(MyNodes.HttpNode)
      # => %{
      #   id: "http_request",
      #   label: "HTTP Request",
      #   inputs: [%{id: "exec", label: "Exec"}, %{id: "url", label: "Url"}],
      #   outputs: [%{id: "success", label: "Success"}, %{id: "error", label: "Error"}]
      # }
  """
  @spec to_rete(module()) :: map()
  def to_rete(module) do
    definition = module.definition()

    %{
      id: definition.name,
      label: definition.title,
      inputs: definition |> Map.get(:inputs, []) |> Enum.map(&port_to_rete/1),
      outputs: definition |> Map.get(:outputs, []) |> Enum.map(&port_to_rete/1)
    }
    |> maybe_put(:category, definition)
    |> maybe_put(:icon, definition)
  end

  defp port_to_rete(port) when is_atom(port) do
    %{id: Atom.to_string(port), label: humanize(port)}
  end

  defp port_to_rete(port) when is_binary(port) do
    %{id: port, label: port}
  end

  defp port_to_rete(%{} = port), do: port

  defp humanize(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp maybe_put(map, key, definition) do
    case Map.get(definition, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
