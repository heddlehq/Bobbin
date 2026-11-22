defmodule Bobbin.TestHost do
  @moduledoc """
  A `Bobbin.Host` for an integration's own tests, so they run without Heddle.

  It fills `{{path.to.value}}` placeholders, decodes JSON fields, and returns the
  credentials a test puts in `:bobbin, :test_credentials`, by name:

      Application.put_env(:bobbin, :host, Bobbin.TestHost)
      Application.put_env(:bobbin, :test_credentials, %{"main" => %{"token" => "t"}})

  A credential can be a function of the options too, to try an OAuth renewal:
  `fn opts -> ... end`.
  """

  @behaviour Bobbin.Host

  @placeholder ~r/\{\{\s*(.*?)\s*\}\}/

  @impl true
  def fetch(context, path) when is_map(context) and is_binary(path) do
    path
    |> String.trim()
    |> String.split(".", trim: true)
    |> Enum.reduce_while(context, fn key, value -> step(value, key) end)
  end

  defp step(map, key) when is_map(map), do: {:cont, Map.get(map, key)}

  defp step(list, key) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} -> {:cont, Enum.at(list, index)}
      _other -> {:halt, nil}
    end
  end

  defp step(_value, _key), do: {:halt, nil}

  @impl true
  def render(template, context) when is_binary(template) do
    Regex.replace(@placeholder, template, fn _match, path -> text(fetch(context, path)) end)
  end

  def render(_template, _context), do: ""

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(value), do: JSON.encode!(value)

  @impl true
  def json(template, context, check) do
    rendered =
      Regex.replace(@placeholder, template, fn _match, path ->
        JSON.encode!(fetch(context, path))
      end)

    with {:ok, value} <- decode(rendered),
         :ok <- check.(value),
         do: {:ok, value}
  end

  defp decode(""), do: {:ok, nil}

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "is not valid JSON"}
    end
  end

  @impl true
  def credential(_workspace_id, name, kind, opts) do
    case Map.get(Application.get_env(:bobbin, :test_credentials, %{}), name) do
      nil -> {:error, "There is no #{kind} credential called #{name}."}
      fun when is_function(fun, 1) -> fun.(opts)
      values -> {:ok, values}
    end
  end
end
