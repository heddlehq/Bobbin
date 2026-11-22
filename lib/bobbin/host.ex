defmodule Bobbin.Host do
  @moduledoc """
  What the app that runs the nodes gives them: Heddle keeps the credentials of each
  workspace. Templates are filled by `Bobbin.Template`, the same in Heddle and in an
  integration's tests.

  The host names its module in config:

      config :bobbin, :host, MyApp.BobbinHost

  `Bobbin.Service` calls it, so an integration never depends on the host.
  """

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
  def credential(workspace_id, name, kind, opts),
    do: host().credential(workspace_id, name, kind, opts)

  defp host do
    Application.get_env(:bobbin, :host) ||
      raise "No Bobbin host: set `config :bobbin, :host, MyHost`, see Bobbin.Host."
  end
end
