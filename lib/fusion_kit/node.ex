defmodule FusionFlow.Node do
  @moduledoc """
  Defines the behavior and macros for creating FusionFlow nodes.

  A node is the fundamental unit of logic in a flow. It consists of a `definition/0`
  describing its interface and a `handler/3` to process data.

  ## Example

      defmodule MyNodes.HttpNode do
        use FusionFlow.Node

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
        def handler(config, context, _input) do
          # Logic: config holds UI values, context holds variables
          {:ok, context, :success}
        end
      end
  """

  @type config :: map()
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
  @callback handler(config(), context(), input()) ::
              {:ok, context(), output_port()}
              | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour FusionFlow.Node
      import FusionFlow.Node, only: [definition: 1]
    end
  end

  @doc """
  Macro to define the node metadata.
  """
  defmacro definition(do: block) do
    quote do
      @impl FusionFlow.Node
      def definition do
        unquote(block)
      end
    end
  end
end
