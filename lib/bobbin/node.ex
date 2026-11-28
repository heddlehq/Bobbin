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
      `fun` can also answer `{:wait, wait}`, to pause there, like a tool that needs a
      person's approval first.
    * `{:wait, wait}`: the run pauses, holding no worker, until `Bobbin.Host.resume_run/4`,
      a person's decision or its time limit. See `wait_for_call/2` and
      `wait_for_approval/2`.

  A wait made with `again: true` calls the handler again when it ends, with what ended
  it in the context as `"resumed"`: `%{"by" => "call" | "timeout", "request" => value,
  "wait" => wait}`. The node then picks up where it stopped, with what it kept in the
  wait's `"data"`.
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
  `again: true` calls the handler again instead, see `c:handler/2`, and `data:` is
  kept with the wait for it.
  """
  @spec wait_for_call(String.t(), keyword()) :: {:wait, wait()}
  def wait_for_call(key, opts \\ []) when is_binary(key) do
    %{"call" => true, "key" => key}
    |> wait(opts)
  end

  @doc """
  Pauses the run until a person approves or rejects it, on the host's approvals page,
  as an Approval node does. `title` says what to approve, and `details:` more.

  What the person decided comes back as `result`, `%{"decision" => "approved" |
  "rejected", "by" => email, "comment" => text}`, through `output` (`"success"`).
  Takes the options of `wait_for_call/2`, like `again: true` and `data:`.
  """
  @spec wait_for_approval(String.t(), keyword()) :: {:wait, wait()}
  def wait_for_approval(title, opts \\ []) when is_binary(title) do
    approval = %{"title" => title, "details" => to_string(Keyword.get(opts, :details, ""))}

    %{"call" => true, "approval" => approval}
    |> wait(opts)
  end

  defp wait(wait, opts) do
    outputs = %{
      "call" => to_string(Keyword.get(opts, :output, "success")),
      "timeout" => to_string(Keyword.get(opts, :timeout_output, "timeout"))
    }

    wait =
      wait
      |> Map.put("outputs", outputs)
      |> put_if("again", Keyword.get(opts, :again, false) == true)
      |> put_if("data", Keyword.get(opts, :data))

    case Keyword.get(opts, :timeout) do
      nil ->
        {:wait, wait}

      seconds when is_integer(seconds) and seconds > 0 ->
        at = DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()
        {:wait, Map.put(wait, "resume_at", at)}
    end
  end

  defp put_if(wait, _key, value) when value in [nil, false], do: wait
  defp put_if(wait, key, value), do: Map.put(wait, key, value)

  @typedoc """
  A section of a node's panel, see `c:panel/2`: a `title`, and either `rows` under
  `columns` (each row a map by column), or `text`. `empty` is what shows without rows.
  """
  @type panel_section :: %{
          required(:title) => String.t(),
          optional(:columns) => [String.t()],
          optional(:rows) => [map()],
          optional(:text) => String.t(),
          optional(:empty) => String.t()
        }

  @typedoc "A message of a chat, see `c:chat_history/3`."
  @type chat_message :: %{
          required(:role) => :visitor | :agent,
          required(:text) => String.t(),
          optional(:at) => DateTime.t() | String.t()
        }

  @doc """
  What the host shows in the drawer of this node, for a flow of `workspace_id` whose
  node has `controls`: a list of sections, like the instances of an agent. Only for
  the nodes that have something to show while their flow runs.
  """
  @callback panel(workspace_id :: term(), controls :: map()) :: [panel_section()]

  @doc """
  A trigger with this callback has a public chat page: the host gives it a link, and
  each message a visitor sends there comes here, with the `conversation` the visitor
  is in. The node starts the runs that answer it, and keeps the conversation, which
  the host reads with `c:chat_history/3`. Answers `{:ok, term}` or `{:error, message}`,
  which the visitor sees.
  """
  @callback chat_message(
              workspace_id :: term(),
              controls :: map(),
              conversation :: String.t(),
              text :: String.t()
            ) :: {:ok, term()} | {:error, String.t()}

  @doc "The messages of `conversation` so far, oldest first, see `c:chat_message/4`."
  @callback chat_history(workspace_id :: term(), controls :: map(), conversation :: String.t()) ::
              [chat_message()]

  @optional_callbacks panel: 2, chat_message: 4, chat_history: 3

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
