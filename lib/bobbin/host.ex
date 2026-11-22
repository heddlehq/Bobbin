defmodule Bobbin.Host do
  @moduledoc """
  What the app that runs the nodes gives them: Heddle fills templates with what the
  flow's steps returned, and keeps the credentials of each workspace.

  The host names its module in config:

      config :bobbin, :host, MyApp.BobbinHost

  `Bobbin.Service` calls it, so an integration never depends on the host.
  """

  @doc "The value at `path` in a run's `context`, like `result.items.0`."
  @callback fetch(context :: map(), path :: String.t()) :: term()

  @doc "Fills the `{{placeholders}}` of `template` from `context`, as text."
  @callback render(template :: term(), context :: map()) :: String.t()

  @doc """
  Decodes `template`, JSON with placeholders, into a value. `check` validates it.
  Returns `{:ok, value}` or `{:error, message}`.
  """
  @callback json(template :: String.t(), context :: map(), check :: (term() -> term())) ::
              {:ok, term()} | {:error, String.t()}

  @doc """
  The values of the credential called `name` of `kind`, as `workspace_id` sees it.
  `refresh: true` in `opts` renews an OAuth token first.
  """
  @callback credential(
              workspace_id :: term(),
              name :: String.t() | nil,
              kind :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, String.t()}

  @doc false
  def fetch(context, path), do: host().fetch(context, path)
  @doc false
  def render(template, context), do: host().render(template, context)
  @doc false
  def json(template, context, check), do: host().json(template, context, check)
  @doc false
  def credential(workspace_id, name, kind, opts),
    do: host().credential(workspace_id, name, kind, opts)

  defp host do
    Application.get_env(:bobbin, :host) ||
      raise "No Bobbin host: set `config :bobbin, :host, MyHost`, see Bobbin.Host."
  end
end
