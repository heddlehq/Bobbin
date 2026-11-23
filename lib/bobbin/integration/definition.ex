defmodule Bobbin.Integration.Definition do
  @moduledoc """
  The node definitions of a `Bobbin.Integration`: one per action and one per trigger.
  """

  alias Bobbin.Service, as: Integration

  @doc "The module of `action` (or trigger) of `manifest`, under `namespace`."
  def module_name(namespace, manifest, action) do
    Module.concat([namespace, Macro.camelize(manifest.id), camelize(action.name)])
  end

  @doc false
  def camelize(name) do
    name
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
    |> Enum.map_join(fn <<first::utf8, rest::binary>> ->
      String.upcase(<<first::utf8>>) <> rest
    end)
  end

  @doc """
  The node definition of `action`. Besides what `Bobbin.Service.definition/4` gives,
  it has the `integration` id, the `resource` the action works on (or nil), and
  `i18n`, its texts in each language the manifest has, see `translations/3`.

  Each of its `ui_fields` has `type` (`text`, `select`, `multiselect`, `boolean`,
  `json` or `date`; a `number` is `text`), `required`, and `options_from: true` when
  the host lists its options from the service, see
  `Bobbin.Integration.Runtime.options/4`.
  """
  def definition(manifest, action) do
    service = %{
      title: manifest.name,
      category: String.to_atom(manifest.category),
      credential: manifest.credential && manifest.credential.kind,
      icon: manifest.icon
    }

    service
    |> Integration.definition(action.name, action.description, ui_fields(action))
    |> Map.merge(%{
      integration: manifest.id,
      resource: action.resource,
      i18n: translations(manifest, "actions", action)
    })
  end

  @trigger_color "bg-emerald-500/15 text-emerald-700 dark:text-emerald-300"

  @doc """
  The node definition of `trigger`: a node a flow starts from, once for each new item.
  A polling trigger has `poll` (see `Bobbin.Integration.Runtime.poll/3`); a webhook
  trigger has `webhook`, with `manual: true` when the person pastes its address in the
  service by hand (see `Bobbin.Integration.Webhook`).
  """
  def trigger_definition(manifest, trigger) do
    name = "#{manifest.name}: #{trigger.name}"
    kind = manifest.credential && manifest.credential.kind
    credential = if kind, do: [Integration.credential_field(kind)], else: []

    %{
      name: name,
      title: name,
      category: String.to_atom(manifest.category),
      color: @trigger_color,
      description: trigger.description,
      icon: manifest.icon,
      inputs: [],
      outputs: [:exec],
      show: true,
      ui_fields: credential ++ ui_fields(trigger),
      integration: manifest.id,
      resource: trigger.resource,
      i18n: translations(manifest, "triggers", trigger)
    }
    |> Map.merge(start(trigger))
  end

  defp start(%{webhook: %{} = webhook} = trigger),
    do: %{webhook: %{trigger: trigger.name, manual: webhook.register == nil}}

  defp start(trigger), do: %{poll: %{trigger: trigger.name, every: trigger.poll.every}}

  @doc """
  The texts of an action or trigger in each language the manifest translates:
  `%{"pt-BR" => %{name: "...", description: "...", fields: %{"title" => "Título"}}}`,
  with only the texts it has.
  """
  def translations(manifest, kind, step) do
    for {locale, texts} <- manifest.i18n || %{},
        %{} = own <- [get_in(texts, [kind, step.name]) || %{}],
        into: %{} do
      labels = if is_map(own["fields"]), do: own["fields"], else: %{}

      {locale,
       %{
         name: text(own["name"]),
         description: text(own["description"]),
         fields: for({name, label} <- labels, is_binary(label), into: %{}, do: {name, label})
       }}
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp ui_fields(action) do
    Enum.map(action.fields, fn field ->
      %{
        type: String.to_atom(field.type),
        name: String.to_atom(field.name),
        label: field.label,
        default: field.default,
        required: field.required
      }
      |> put_options(field.options)
      |> then(&if(field.options_from, do: Map.put(&1, :options_from, true), else: &1))
      |> Map.update!(:type, &if(&1 == :number, do: :text, else: &1))
    end)
  end

  defp put_options(field, nil), do: field

  defp put_options(field, options) do
    Map.put(
      field,
      :options,
      Enum.map(options, &%{label: to_string(&1["label"]), value: to_string(&1["value"])})
    )
  end
end
