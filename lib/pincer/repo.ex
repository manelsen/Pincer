defmodule Pincer.Infra.Repo do
  use Ecto.Repo,
    otp_app: :pincer,
    adapter: Ecto.Adapters.SQLite3
end
