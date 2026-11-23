defmodule Bobbin.Integration do
  @moduledoc """
  An integration written as a manifest: a YAML file that describes a service's
  credential and its actions as HTTP requests, with no code.

  Each action becomes a node in Heddle, with a `success` and an `error` output.

  ## Example

  ```yaml
  id: acme
  name: Acme
  version: 1.0.0
  description: Tickets in Acme.
  icon: hero-ticket
  base_url: https://api.acme.test/v1/

  credential:
    label: Acme
    fields:
      - name: api_key
        label: API key
        secret: true
    auth:
      type: header
      name: X-Api-Key
      value: "{{credential.api_key}}"

  actions:
    - name: Create Ticket
      description: Opens a ticket.
      fields:
        - name: title
          label: Title
      request:
        method: POST
        path: tickets
        body:
          title: "{{fields.title}}"
      output:
        pick: [id, url]
  ```

  ## Templates

  Strings in `request`, `credential.auth` and `output.value` may hold
  `{{fields.<name>}}` and `{{credential.<name>}}`. A string that is a single
  placeholder keeps the value's type. Values that end up empty are left out of the
  query and the body, so optional fields need no extra syntax.

  ## Fields

  `type` is `text` (the default), `textarea`, `number`, `select` or `multiselect`
  (with `options`), `boolean`, `json` or `datetime`. Each is sent as its kind: a
  boolean as `true` or `false`, JSON as what it describes, a multiselect as a list. A
  `required` field that is empty fails the action. `resource` on an action names
  what it works on (Contact, Deal), for Heddle to group actions by.

  ## Address

  `base_url` may take values of the credential, for services with an address per
  account (`https://{{credential.subdomain}}.zendesk.com/`) or run by the user
  (`{{credential.url}}/api/`). See the guide for what such a value may hold.

  ## Languages

  `i18n` maps a locale (`pt-BR`) to its texts: `description`, and under
  `actions.<name>` or `triggers.<name>` a `name`, a `description` and `fields` labels.
  See `translate/3`.

  ## Options from the service

  A `select` or `multiselect` may list its options from the service, with
  `options_from`: a `request` (which may use other fields, like
  `{{fields.spreadsheet}}`), the `path` of the items in the answer, and the keys of
  each item that are its `label` and its `value` (`name` and `id` when left out). It
  may have `pagination`, like an action. Heddle calls `Bobbin.Integration.Request.options/6`
  when someone opens the field.

  ## Credential `auth` types

    * `bearer`: `token`
    * `header`: `name` and `value`
    * `query`: `name` and `value`
    * `basic`: `username` and `password`
    * `oauth2`: `authorize_url`, `token_url` and `scopes`. The host runs the
      authorization and passes the access token as `{{credential.access_token}}`.
    * `client_credentials`: `token_url`, `client_id`, `client_secret`, `scopes`.
      Bobbin fetches the token and keeps it, see `Bobbin.Integration.Auth`.
    * `login`: a `request` that returns a token at `token_path`, put on each request
      by `apply` (an auth of the types above, with `{{auth.token}}`).
    * `jwt`: a token signed for each request (`algorithm`, `key`, `claims`).
    * `hmac`: a signature of each request (`secret`, `message`, `signature`).
    * `aws_sigv4`: `access_key_id`, `secret_access_key`, `region`, `service`.
    * `none`

  `credential.tls` holds a client certificate (`cert` and `key`, PEM) for services
  that ask for one.

  `headers` go in every request, like an API version. A request's own headers win.

  ## Responses

    * `errors.ok_path`: a field of the body that must be `true`, for APIs that
      answer 200 when something failed. `errors.message_path` holds why.
    * `output.path`: the part of the body the node returns, like `data.items`.
    * `output.pick`: the keys to keep, from each item of a list.
    * `output.value`: a value built from templates, in place of the body.

  ## Pagination

  `pagination.type` is `cursor`, `offset`, `page` (a page number) or `link` (the
  `Link` header). The node
  returns the items of every page, from `pagination.items_path`. `pagination.in: body`
  puts the page parameters in the JSON body, at paths like `variables.after`, and
  `has_more_path` stops a cursor when the answer says there's nothing more.

  ## Triggers

  `triggers` start a flow when something new shows up in the service. A trigger is
  written like an action whose output is a list, plus `poll`:

  ```yaml
  triggers:
    - name: New Ticket
      request:
        method: GET
        path: tickets
      output:
        path: tickets
      poll:
        every: 5   # minutes, 5 when left out
        id: id     # the key that tells items apart, "id" when left out
  ```

  The host calls the request every `every` minutes and starts the flow once for each
  item whose `id` it hasn't seen. The first call only records what is already there.

  See `priv/integration.schema.json` for the full format.
  """

  @type t :: %{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          icon: String.t(),
          category: String.t(),
          base_url: String.t(),
          headers: map(),
          i18n: map(),
          credential: map() | nil,
          errors: map(),
          actions: [map()],
          triggers: [map()]
        }

  @auth_types ~w(bearer header query basic oauth2 client_credentials login jwt hmac aws_sigv4 none)
  @methods ~w(GET POST PUT PATCH DELETE)
  @field_types ~w(text textarea number select boolean json multiselect datetime file)
  @pagination_types ~w(cursor offset page link)
  @id ~r/\A[a-z][a-z0-9_]*\z/
  @version ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?\z/

  @doc "Reads and checks the manifest at `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(path) do
    case File.read(path) do
      {:ok, yaml} -> parse(yaml)
      {:error, reason} -> {:error, ["Can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Like `load/1`, raising with what is wrong."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, integration} -> integration
      {:error, errors} -> raise ArgumentError, "#{path}:\n  " <> Enum.join(errors, "\n  ")
    end
  end

  @doc "Parses and checks a manifest written in YAML."
  @spec parse(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(yaml) do
    case aliases(yaml) do
      [] ->
        decode(yaml)

      lines ->
        {:error,
         Enum.map(
           lines,
           &"Line #{&1} uses a YAML alias (*name), which isn't supported. Write the value out."
         )}
    end
  end

  # yamerl resolves an alias of a mapping to its first key, so `*task_id`
  # would quietly become "name". Quoted text and comments are skipped.
  defp aliases(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _number} ->
      line
      |> String.replace(~r/"(?:[^"\\]|\\.)*"|'[^']*'/, "")
      |> String.replace(~r/(^|\s)#.*$/, "")
      |> String.match?(~r/(^\s*|:\s+|-\s+|[\[{,]\s*)\*[\w-]+\s*([,\]}]|$)/)
    end)
    |> Enum.map(fn {_line, number} -> number end)
  end

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> validate(map)
      {:ok, _other} -> {:error, ["The manifest must be a map."]}
      {:error, error} -> {:error, ["Invalid YAML: #{Exception.message(error)}"]}
    end
  end

  @doc "Checks a manifest already decoded into a map with string keys."
  @spec validate(map()) :: {:ok, t()} | {:error, [String.t()]}
  def validate(map) do
    errors =
      []
      |> required(map, "id", @id, "a lowercase id, like acme_crm")
      |> required(map, "name")
      |> required(map, "version", @version, "a version like 1.0.0")
      |> required(
        map,
        "base_url",
        ~r/\A(https?:\/\/|\{\{\s*credential\.)/,
        "a URL starting with http"
      )
      |> check_i18n(map["i18n"])
      |> check_credential(map["credential"])
      |> check_actions(map["actions"])
      |> check_triggers(map["triggers"])

    if errors == [], do: {:ok, normalize(map)}, else: {:error, Enum.reverse(errors)}
  end

  @doc "The action called `name`, or nil."
  @spec action(t(), String.t()) :: map() | nil
  def action(integration, name), do: Enum.find(integration.actions, &(&1.name == name))

  @doc """
  The text at `path` of the manifest's translation to `locale`, or nil when it has
  none: `translate(integration, "pt-BR", ["actions", "Create Ticket", "name"])`.
  """
  @spec translate(t(), String.t(), [String.t()]) :: String.t() | nil
  def translate(integration, locale, path) do
    case get_in(integration.i18n, [locale | path]) do
      text when is_binary(text) -> text
      _other -> nil
    end
  end

  @doc "The trigger called `name`, or nil."
  @spec trigger(t(), String.t()) :: map() | nil
  def trigger(integration, name), do: Enum.find(integration.triggers, &(&1.name == name))

  ## Checks

  defp required(errors, map, key, format \\ nil, hint \\ nil) do
    case map[key] do
      value when is_binary(value) and value != "" ->
        if format && not Regex.match?(format, value),
          do: ["#{key} must be #{hint}" | errors],
          else: errors

      _missing ->
        ["#{key} is required" | errors]
    end
  end

  defp check_i18n(errors, nil), do: errors

  defp check_i18n(errors, i18n) when is_map(i18n) do
    Enum.reduce(i18n, errors, fn
      {_locale, texts}, errors when is_map(texts) -> errors
      {locale, _texts}, errors -> ["i18n.#{locale} must be a map" | errors]
    end)
  end

  defp check_i18n(errors, _other), do: ["i18n must map each language to its texts" | errors]

  defp check_credential(errors, nil), do: errors

  defp check_credential(errors, credential) when is_map(credential) do
    errors = check_fields(errors, "credential", credential["fields"] || [])

    errors =
      case credential["tls"] do
        nil -> errors
        %{"cert" => cert, "key" => key} when is_binary(cert) and is_binary(key) -> errors
        _other -> ["credential.tls needs a cert and a key" | errors]
      end

    case credential["auth"] do
      %{"type" => type} = auth when type in @auth_types ->
        check_auth(errors, type, auth)

      %{"type" => type} ->
        [
          "credential.auth.type #{inspect(type)} is not one of #{Enum.join(@auth_types, ", ")}"
          | errors
        ]

      _other ->
        ["credential.auth.type is required" | errors]
    end
  end

  defp check_credential(errors, _other), do: ["credential must be a map" | errors]

  @auth_keys %{
    "client_credentials" => ~w(token_url client_id client_secret),
    "login" => ~w(request token_path),
    "jwt" => ~w(key),
    "hmac" => ~w(secret message signature),
    "aws_sigv4" => ~w(access_key_id secret_access_key region service)
  }

  defp check_auth(errors, type, auth) do
    errors =
      @auth_keys
      |> Map.get(type, [])
      |> Enum.reject(&Map.has_key?(auth, &1))
      |> Enum.reduce(errors, &["credential.auth needs #{&1} for #{type}" | &2])

    jwt = Bobbin.Integration.Auth.jwt_algorithms()
    hmac = Bobbin.Integration.Auth.hmac_algorithms()

    cond do
      type == "jwt" and Map.get(auth, "algorithm", "HS256") not in jwt ->
        ["credential.auth.algorithm must be one of #{Enum.join(jwt, ", ")}" | errors]

      type == "hmac" and Map.get(auth, "algorithm", "sha256") not in hmac ->
        ["credential.auth.algorithm must be one of #{Enum.join(hmac, ", ")}" | errors]

      type == "hmac" and not match?(%{"query" => _}, auth["signature"]) and
          not match?(%{"header" => _}, auth["signature"]) ->
        ["credential.auth.signature needs a header or a query name" | errors]

      true ->
        errors
    end
  end

  defp check_actions(errors, [_ | _] = actions) do
    names = Enum.map(actions, &(is_map(&1) && &1["name"]))

    errors =
      if length(Enum.uniq(names)) == length(names),
        do: errors,
        else: ["actions must have different names" | errors]

    actions
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {action, index}, errors -> check_action(errors, action, index) end)
  end

  defp check_actions(errors, _other), do: ["actions must list at least one action" | errors]

  defp check_triggers(errors, nil), do: errors

  defp check_triggers(errors, triggers) when is_list(triggers) do
    names = Enum.map(triggers, &(is_map(&1) && &1["name"]))

    errors =
      if length(Enum.uniq(names)) == length(names),
        do: errors,
        else: ["triggers must have different names" | errors]

    triggers
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {trigger, index}, errors when is_map(trigger) ->
        where = "triggers[#{index}]"

        case trigger do
          %{"webhook" => webhook} ->
            errors
            |> check_action(trigger, where, trigger["request"] != nil)
            |> check_webhook(webhook, "#{where}.webhook")

          %{"request" => _request} ->
            errors
            |> check_action(trigger, where)
            |> check_poll(trigger["poll"], where)

          _neither ->
            ["#{where} needs a request to poll or a webhook" | errors]
        end

      {_trigger, index}, errors ->
        ["triggers[#{index}] must be a map" | errors]
    end)
  end

  defp check_triggers(errors, _other), do: ["triggers must be a list" | errors]

  defp check_webhook(errors, webhook, where) when is_map(webhook) do
    errors =
      Enum.reduce(~w(register unregister), errors, fn key, errors ->
        case webhook[key] do
          nil ->
            errors

          %{"request" => %{"method" => method, "path" => path}}
          when method in @methods and is_binary(path) ->
            errors

          _other ->
            ["#{where}.#{key} needs a request with a method and a path" | errors]
        end
      end)

    case webhook["signature"] do
      nil ->
        errors

      %{"header" => header, "secret" => secret} = signature
      when is_binary(header) and is_binary(secret) ->
        hmac = Bobbin.Integration.Auth.hmac_algorithms()

        if Map.get(signature, "algorithm", "sha256") in hmac,
          do: errors,
          else: ["#{where}.signature.algorithm must be one of #{Enum.join(hmac, ", ")}" | errors]

      %{"header" => header, "token" => token} when is_binary(header) and is_binary(token) ->
        errors

      _other ->
        ["#{where}.signature needs a header and a secret (or a token)" | errors]
    end
  end

  defp check_webhook(errors, _webhook, where), do: ["#{where} must be a map" | errors]

  defp check_poll(errors, nil, _where), do: errors

  defp check_poll(errors, poll, where) when is_map(poll) do
    errors =
      case poll["every"] do
        nil -> errors
        every when is_integer(every) and every >= 1 -> errors
        _other -> ["#{where}.poll.every must be a whole number of minutes, 1 or more" | errors]
      end

    case poll["id"] do
      nil -> errors
      id when is_binary(id) and id != "" -> errors
      _other -> ["#{where}.poll.id must be the key that tells items apart" | errors]
    end
  end

  defp check_poll(errors, _poll, where), do: ["#{where}.poll must be a map" | errors]

  defp check_action(errors, action, where, request? \\ true)

  defp check_action(errors, action, index, _request?) when is_map(action) and is_integer(index),
    do: check_action(errors, action, "actions[#{index}]")

  defp check_action(errors, action, where, request?) when is_map(action) do
    request = action["request"]

    errors =
      errors
      |> required_in(action, "name", where)
      |> check_fields(where, action["fields"] || [])

    errors =
      case request do
        nil when not request? ->
          errors

        %{"method" => method, "path" => path} when method in @methods and is_binary(path) ->
          errors

        %{"method" => method} when method not in @methods ->
          ["#{where}.request.method must be one of #{Enum.join(@methods, ", ")}" | errors]

        _other ->
          ["#{where}.request needs a method and a path" | errors]
      end

    case action["pagination"] do
      nil ->
        errors

      %{"in" => place} when place not in ["query", "body"] ->
        ["#{where}.pagination.in must be query or body" | errors]

      %{"type" => type} when type in @pagination_types ->
        errors

      _other ->
        [
          "#{where}.pagination needs a type (#{Enum.join(@pagination_types, ", ")})"
          | errors
        ]
    end
  end

  defp check_action(errors, _action, index, _request?) when is_integer(index),
    do: ["actions[#{index}] must be a map" | errors]

  defp required_in(errors, map, key, where) do
    case map[key] do
      value when is_binary(value) and value != "" -> errors
      _missing -> ["#{where}.#{key} is required" | errors]
    end
  end

  defp check_fields(errors, where, fields) when is_list(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {%{"name" => name} = field, index}, errors when is_binary(name) ->
        type = field["type"] || "text"

        cond do
          type not in @field_types ->
            [
              "#{where}.fields[#{index}].type must be one of #{Enum.join(@field_types, ", ")}"
              | errors
            ]

          field["options_from"] != nil ->
            check_options_from(errors, field["options_from"], "#{where}.fields[#{index}]")

          type in ["select", "multiselect"] and not is_list(field["options"]) ->
            ["#{where}.fields[#{index}] is a #{type} and needs options" | errors]

          true ->
            errors
        end

      {_field, index}, errors ->
        ["#{where}.fields[#{index}] needs a name" | errors]
    end)
  end

  defp check_fields(errors, where, _fields), do: ["#{where}.fields must be a list" | errors]

  defp check_options_from(errors, %{"request" => %{"method" => method, "path" => path}}, _where)
       when method in @methods and is_binary(path),
       do: errors

  defp check_options_from(errors, _from, where),
    do: ["#{where}.options_from needs a request with a method and a path" | errors]

  ## Normalizing

  defp normalize(map) do
    id = map["id"]

    %{
      id: id,
      name: map["name"],
      version: map["version"],
      description: map["description"] || "",
      icon: map["icon"] || "hero-puzzle-piece",
      category: map["category"] || id,
      base_url: map["base_url"],
      headers: map["headers"] || %{},
      i18n: map["i18n"] || %{},
      credential: normalize_credential(map["credential"], map),
      errors: %{
        ok_path: get_in(map, ["errors", "ok_path"]),
        message_path: get_in(map, ["errors", "message_path"])
      },
      actions: Enum.map(map["actions"], &normalize_action/1),
      triggers: Enum.map(map["triggers"] || [], &normalize_trigger/1)
    }
  end

  defp normalize_credential(nil, _map), do: nil

  defp normalize_credential(credential, map) do
    %{
      kind: credential["kind"] || map["id"],
      label: credential["label"] || map["name"],
      fields: Enum.map(credential["fields"] || [], &normalize_field/1),
      auth: credential["auth"],
      tls: credential["tls"]
    }
  end

  defp normalize_trigger(trigger) do
    poll = trigger["poll"] || %{}

    trigger
    |> normalize_action()
    |> Map.put(:poll, %{every: poll["every"] || 5, id: poll["id"] || "id"})
    |> Map.put(:webhook, normalize_webhook(trigger["webhook"]))
  end

  defp normalize_webhook(nil), do: nil

  defp normalize_webhook(webhook) do
    step = fn
      nil ->
        nil

      step ->
        %{
          request: normalize_request(step["request"]),
          id_path: step["id_path"],
          secret_path: step["secret_path"]
        }
    end

    %{
      register: step.(webhook["register"]),
      unregister: step.(webhook["unregister"]),
      signature: webhook["signature"],
      challenge: webhook["challenge"],
      output: webhook["output"] || %{}
    }
  end

  defp normalize_action(action) do
    %{
      name: action["name"],
      description: action["description"] || "",
      resource: action["resource"],
      fields: Enum.map(action["fields"] || [], &normalize_field/1),
      request: normalize_request(action["request"]),
      output: action["output"] || %{},
      pagination: action["pagination"]
    }
  end

  defp normalize_request(nil), do: nil

  defp normalize_request(request) do
    %{
      method: request["method"],
      path: request["path"],
      headers: request["headers"] || %{},
      query: request["query"] || %{},
      body: request["body"],
      body_type: request["body_type"] || "json"
    }
  end

  defp normalize_options_from(nil), do: nil

  defp normalize_options_from(from) do
    %{
      request: normalize_request(from["request"]),
      path: from["path"],
      label: from["label"] || "name",
      value: from["value"] || "id",
      pagination: from["pagination"]
    }
  end

  defp normalize_field(field) do
    type = field["type"] || "text"

    %{
      name: field["name"],
      label: field["label"] || field["name"],
      type: type,
      default: default(type, field["default"]),
      options: field["options"],
      options_from: normalize_options_from(field["options_from"]),
      secret: field["secret"] == true,
      required: field["required"] == true,
      strip: field["strip"]
    }
  end

  # Text fields keep their default as text, the others as written: false, a map, a list.
  defp default(type, value) when type in ~w(boolean json multiselect), do: value
  defp default(_type, value), do: to_string(value || "")
end
