defmodule Pincer.Storage.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :session_id, :string
    field :role, :string
    field :content, :string
    field :embedding, :binary

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :role, :content, :embedding])
    |> validate_required([:session_id, :role, :content])
  end
end
