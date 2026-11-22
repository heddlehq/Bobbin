defmodule Bobbin.TestHost do
  @moduledoc """
  A `Bobbin.Host` for an integration's own tests, so they run without Heddle.

  It returns the credentials a test puts in `:bobbin, :test_credentials`, by name:

      Application.put_env(:bobbin, :host, Bobbin.TestHost)
      Application.put_env(:bobbin, :test_credentials, %{"main" => %{"token" => "t"}})

  A credential can be a function of the options too, to try an OAuth renewal:
  `fn opts -> ... end`. Or name a module in `:bobbin, :credentials_client` whose
  `fetch(workspace_id, name, kind)`, and `fetch/4` with options, answers.
  """

  @behaviour Bobbin.Host

  @impl true
  def credential(workspace_id, name, kind, opts) do
    case Application.get_env(:bobbin, :credentials_client) do
      nil -> from_config(name, kind, opts)
      client when opts == [] -> client.fetch(workspace_id, name, kind)
      client -> client.fetch(workspace_id, name, kind, opts)
    end
  end

  defp from_config(name, kind, opts) do
    case Map.get(Application.get_env(:bobbin, :test_credentials, %{}), name) do
      nil -> {:error, "There is no #{kind} credential called #{name}."}
      fun when is_function(fun, 1) -> fun.(opts)
      values -> {:ok, values}
    end
  end
end
