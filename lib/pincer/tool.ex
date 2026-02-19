defmodule Pincer.Tool do
  @moduledoc """
  Behavior for Pincer Tools (Capabilities).
  """
  @callback spec() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, any()}
end
