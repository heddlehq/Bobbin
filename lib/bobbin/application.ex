defmodule Bobbin.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Bobbin.Integration.Auth.create_table()

    children = [
      {Registry, keys: :unique, name: Bobbin.Connections.Registry},
      {DynamicSupervisor, name: Bobbin.Connections.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Bobbin.Supervisor)
  end
end
