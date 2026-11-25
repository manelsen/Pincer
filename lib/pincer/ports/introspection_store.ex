defmodule Pincer.Ports.IntrospectionStore do
  @moduledoc "Persistence for the lessons and self-state maintained by introspection."

  @type lesson_query :: :active | {:top, non_neg_integer(), number()}
  @type write_result :: {:ok, map()} | {:error, term()}
  @type state_result :: {:ok, map() | nil} | {:error, term()}

  @callback insert_lesson(map()) :: write_result()
  @callback update_lesson(map()) :: write_result()
  @callback get_lesson(String.t()) :: map() | nil
  @callback list_lessons(String.t(), lesson_query()) :: [map()]
  @callback get_self_state(String.t()) :: state_result()
  @callback insert_self_state(map()) :: write_result()
  @callback update_self_state(String.t(), map()) :: write_result()

  @doc "Persists a validated new lesson."
  @spec insert_lesson(map()) :: write_result()
  def insert_lesson(lesson), do: adapter().insert_lesson(lesson)

  @doc "Persists changes to a validated lesson."
  @spec update_lesson(map()) :: write_result()
  def update_lesson(lesson), do: adapter().update_lesson(lesson)

  @doc "Retrieves a lesson by ID."
  @spec get_lesson(String.t()) :: map() | nil
  def get_lesson(id), do: adapter().get_lesson(id)

  @doc "Lists all active or top-ranked lessons for the given agent."
  @spec list_lessons(String.t(), lesson_query()) :: [map()]
  def list_lessons(agent_id, query), do: adapter().list_lessons(agent_id, query)

  @doc "Retrieves the agent's stored self-state, if present."
  @spec get_self_state(String.t()) :: state_result()
  def get_self_state(agent_id), do: adapter().get_self_state(agent_id)

  @doc "Persists an initial self-state or returns the existing state."
  @spec insert_self_state(map()) :: write_result()
  def insert_self_state(state), do: adapter().insert_self_state(state)

  @doc "Persists a validated update to an agent's self-state."
  @spec update_self_state(String.t(), map()) :: write_result()
  def update_self_state(agent_id, state), do: adapter().update_self_state(agent_id, state)

  defp adapter, do: Application.fetch_env!(:pincer, :introspection_store_adapter)
end
