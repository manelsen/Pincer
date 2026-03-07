defmodule Pincer.Infra.Repo do
  @moduledoc """
  SQLite3 Ecto repository for persistent storage (messages, sessions, jobs).
  """
  use Ecto.Repo,
    otp_app: :pincer,
    adapter: Ecto.Adapters.SQLite3
end
