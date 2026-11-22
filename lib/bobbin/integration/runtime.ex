defmodule Bobbin.Integration.Runtime do
  @moduledoc """
  Runs the nodes of a `Bobbin.Integration` inside the host: an action answers through
  `success` and `error`, a trigger passes on the item that started the run. The
  credential the node picked comes from the host, see `Bobbin.Host`, and an OAuth
  token the service refuses is renewed once.
  """

  alias Bobbin.Integration, as: Manifest
  alias Bobbin.Integration.Request
  alias Bobbin.Host
  alias Bobbin.Service, as: Integration

  @doc "Runs `action_name` of `manifest` with the node's `context`."
  def run(manifest, action_name, context) do
    action = Manifest.action(manifest, action_name)

    result =
      with_credential(manifest, context, fn credential ->
        Request.run(
          manifest,
          action_name,
          fields(action, context),
          credential,
          Integration.req_options([])
        )
      end)

    case result do
      {:ok, result} -> Integration.success(context, result)
      {:error, message} -> Integration.failure(context, message)
    end
  end

  @doc """
  Calls the trigger `trigger_name` of `manifest` once, with the node's `context`: its
  fields, the credential it picked and its flow's `workspace_id`.

  Returns `{:ok, [{id, item}]}` or `{:error, message}`.
  """
  def poll(manifest, trigger_name, context) do
    trigger = Manifest.trigger(manifest, trigger_name)

    with_credential(manifest, context, fn credential ->
      Request.poll(
        manifest,
        trigger_name,
        fields(trigger, context),
        credential,
        Integration.req_options([])
      )
    end)
  end

  @doc """
  What a trigger node does: passes on the item that started the run as `result`. Run
  from the editor, with no item, it takes the newest the service has, to try the flow.
  """
  def trigger(manifest, trigger_name, context) do
    case context do
      %{"item" => item} ->
        {:ok, Map.put(context, "result", item), :exec}

      _from_the_editor ->
        case poll(manifest, trigger_name, context) do
          {:ok, [{_id, item} | _rest]} ->
            {:ok, Map.put(context, "result", item), :exec}

          {:ok, []} ->
            {:error, "#{manifest.name} has nothing for #{trigger_name} yet."}

          error ->
            error
        end
    end
  end

  # Calls `request` with the credential the node picked, if the manifest takes one.
  defp with_credential(manifest, context, request) do
    kind = manifest.credential && manifest.credential.kind
    oauth? = match?(%{auth: %{"type" => "oauth2"}}, manifest.credential)

    cond do
      kind && oauth? ->
        with {:ok, credential} <- Integration.credential(context, kind) do
          case request.(credential) do
            # The service refused the token: renew it and try once more.
            {:error, message} = error ->
              if String.ends_with?(message, "answered 401") do
                with {:ok, renewed} <- Integration.credential(context, kind, refresh: true),
                     do: request.(renewed)
              else
                error
              end

            result ->
              result
          end
        end

      kind ->
        with {:ok, credential} <- Integration.credential(context, kind), do: request.(credential)

      true ->
        request.(%{})
    end
  end

  # A field the node doesn't set takes its default, which may point at the last step.
  defp fields(action, context) do
    Map.new(action.fields, fn field ->
      template = context[field.name] || field.default
      {field.name, Host.render(template, context)}
    end)
  end
end
