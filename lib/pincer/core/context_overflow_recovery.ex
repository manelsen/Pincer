defmodule Pincer.Core.ContextOverflowRecovery do
  @moduledoc """
  Pure recovery policy for provider-side context overflow failures.

  The executor owns the side effects. This module only decides whether an
  overflow is recoverable and which payload-reduction knobs should be applied
  on the next attempt.
  """

  alias Pincer.Core.ErrorClass

  @type plan :: %{
          safe_limit_scale: float(),
          drop_tools?: boolean()
        }

  @doc """
  Returns an explicit retry plan when the error class is `:context_overflow`.
  """
  @spec plan(term(), keyword()) :: {:retry, plan()} | :noop
  def plan(reason, opts \\ []) do
    if ErrorClass.classify(reason) == :context_overflow do
      {:retry,
       %{
         safe_limit_scale: 0.15,
         drop_tools?: Keyword.get(opts, :tools_present?, false)
       }}
    else
      :noop
    end
  end
end
