defmodule Pincer.Utils.ModelOverride do
  @moduledoc "Normalizes model override maps from configuration and session state."

  alias Pincer.Utils.MapHelpers

  @type t :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          optional(:thinking_level) => term()
        }

  @doc "Returns an atom-keyed model override, or `nil` when an identifier is absent or empty."
  @spec normalize(term()) :: t() | nil
  def normalize(override) when is_map(override) do
    provider = MapHelpers.read_field(override, :provider)
    model = MapHelpers.read_field(override, :model)

    if is_binary(provider) and provider != "" and is_binary(model) and model != "" do
      base = %{provider: provider, model: model}

      thinking = MapHelpers.read_field(override, :thinking_level)
      if thinking, do: Map.put(base, :thinking_level, thinking), else: base
    end
  end

  def normalize(_), do: nil
end
