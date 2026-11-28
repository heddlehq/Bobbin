defmodule Bobbin.Node do
  @moduledoc """
  Defines the behavior and macros for creating Bobbin nodes.

  A node is the fundamental unit of logic in a flow. It consists of a `definition/0`
  describing its interface and a `handler/2` to process data.

  ## Example

      defmodule MyNodes.HttpNode do
        use Bobbin.Node

        definition do
          %{
            name: "http_request",
            title: "HTTP Request",
            category: :network,
            color: "bg-blue-500",
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
          optional(:color) => String.t(),
          optional(:icon) => String.t(),
          optional(:inputs) => [map() | atom() | String.t()],
          optional(:outputs) => [map() | atom() | String.t()],
          optional(atom()) => any()
        }

  @doc """
  Returns the metadata and interface definition for the node.
  """
  @callback definition() :: node_definition()

  @typedoc """
  A tool a node with `{:with_tools, fun}` is given: one of the nodes connected to its
  `tools` output, with a JSON Schema of what to fill in.
  """
  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}

  @typedoc """
  What a node that waits hands the host, see `wait_for_call/2`.
  """
  @type wait :: %{required(String.t()) => term()}

  @doc """
  Processes the node logic.

  Returns `{:ok, new_context, output_port}` on success, or `{:error, reason}` on failure.
  Two more answers ask the host for something:

    * `{:with_tools, fun}`: the node brings its own model. `fun.(tools, call)` gets the
      tools, see `t:tool/0`, and `call.(name, arguments)`, which runs one and answers
      `{:ok, text}` or `{:error, message}`. It answers `{:ok, value}`, which goes on
      through `success`, `{:ok, value, output_port}` or `{:error, reason}`. The host
      keeps `tool_calls` as for its own agent.
    * `{:wait, wait}`: the run pauses, holding no worker, until `Bobbin.Host.resume_run/4`
      or its time limit. See `wait_for_call/2`.
  """
  @callback handler(context(), input()) ::
              {:ok, context(), output_port()}
              | {:error, term()}
              | {:with_tools,
                 (list(tool()), (String.t(), map() -> {:ok, String.t()} | {:error, String.t()}) ->
                    term())}
              | {:wait, wait()}

  @doc """
  Pauses the run until something calls `Bobbin.Host.resume_run/4` with `key`, the
  answer to a question the node sent away, like another agent's reply. What the call
  brings becomes `result`, and the run goes on through `output` (`"success"`).

  `timeout:` is the most it waits, in seconds, and then it goes on through
  `timeout_output` (`"timeout"`). Without it, it waits up to the host's limit.
  """
  @spec wait_for_call(String.t(), keyword()) :: {:wait, wait()}
  def wait_for_call(key, opts \\ []) when is_binary(key) do
    outputs = %{
      "call" => to_string(Keyword.get(opts, :output, "success")),
      "timeout" => to_string(Keyword.get(opts, :timeout_output, "timeout"))
    }

    wait = %{"call" => true, "key" => key, "outputs" => outputs}

    case Keyword.get(opts, :timeout) do
      nil ->
        {:wait, wait}

      seconds when is_integer(seconds) and seconds > 0 ->
        at = DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()
        {:wait, Map.put(wait, "resume_at", at)}
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Bobbin.Node
      import Bobbin.Node, only: [definition: 1]
    end
  end

  @doc """
  Macro to define the node metadata.
  """
  defmacro definition(do: block) do
    quote do
      @impl Bobbin.Node
      def definition do
        unquote(block)
      end
    end
  end
end
