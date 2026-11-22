defmodule Bobbin.Integration.Nodes do
  @moduledoc """
  Turns a manifest shipped in a package into node modules at compile time, for an
  integration that is YAML plus some nodes written in Elixir:

      defmodule MyIntegrations.Slack do
        use Bobbin.Integration.Nodes, manifest: "../priv/integration.yaml"
      end

  The path is relative to the file. Each trigger and action becomes a module under
  the using one, like `MyIntegrations.Slack.Slack.SendMessage`, and the using module
  gets `manifest/0` and `nodes/0`.
  """

  alias Bobbin.Integration.Definition

  defmacro __using__(opts) do
    path = Path.expand(Keyword.fetch!(opts, :manifest), Path.dirname(__CALLER__.file))
    manifest = Bobbin.Integration.load!(path)
    namespace = __CALLER__.module

    trigger_modules =
      for trigger <- manifest.triggers do
        module = Definition.module_name(namespace, manifest, trigger)
        definition = Definition.trigger_definition(manifest, trigger)
        {module, definition, :trigger, trigger.name}
      end

    action_modules =
      for action <- manifest.actions do
        module = Definition.module_name(namespace, manifest, action)
        definition = Definition.definition(manifest, action)
        {module, definition, :action, action.name}
      end

    modules = trigger_modules ++ action_modules

    defs =
      for {module, definition, kind, name} <- modules do
        call =
          case kind do
            :trigger ->
              quote do:
                      Bobbin.Integration.Runtime.trigger(
                        unquote(namespace).manifest(),
                        unquote(name),
                        context
                      )

            :action ->
              quote do:
                      Bobbin.Integration.Runtime.run(
                        unquote(namespace).manifest(),
                        unquote(name),
                        context
                      )
          end

        quote do
          defmodule unquote(module) do
            @moduledoc false
            @behaviour Bobbin.Node

            @impl true
            def definition, do: unquote(Macro.escape(definition))

            @impl true
            def handler(context, _input), do: unquote(call)
          end
        end
      end

    quote do
      @external_resource unquote(path)
      @manifest unquote(Macro.escape(manifest))

      @doc "The manifest these nodes come from."
      def manifest, do: @manifest

      @doc "The node modules of the manifest: its triggers, then its actions."
      def nodes, do: unquote(Enum.map(modules, &elem(&1, 0)))

      unquote_splicing(defs)
    end
  end
end
