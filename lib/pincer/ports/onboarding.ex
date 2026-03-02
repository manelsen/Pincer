defmodule Pincer.Ports.Onboarding do
  @moduledoc """
  Port for onboarding workflows.

  Keeps onboarding contracts explicit so adapters (Mix task, future APIs)
  depend on a stable core interface.
  """

  @type operation ::
          {:mkdir_p, String.t()}
          | {:write_if_missing, String.t(), String.t()}
          | {:write_config_yaml, String.t(), map()}

  @type report :: %{
          created: [String.t()],
          written: [String.t()],
          skipped: [String.t()]
        }

  @callback defaults() :: map()
  @callback plan(config :: map()) :: [operation()]
  @callback apply_plan(operations :: [operation()], opts :: keyword()) ::
              {:ok, report()} | {:error, term()}
end
