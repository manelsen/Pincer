defmodule Pincer.Infra.Repo do
  @moduledoc """
  PostgreSQL Ecto repository for persistent storage and pgvector-backed search.
  """
  use Ecto.Repo,
    otp_app: :pincer,
    adapter: Ecto.Adapters.Postgres
end
