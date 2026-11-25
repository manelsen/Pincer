defmodule Pincer.Channels.Shared.ProjectBridge do
  @moduledoc """
  Shared project wizard and runner bridge for channel adapters.

  Centralizes `continue/3`, `kickoff/2`, `on_agent_response/2`, and
  `on_agent_error/2` on top of `PincerPorts.Project` and `PincerPorts.Session`,
  keeping channel-specific transport callbacks in each adapter.
  """

  require Logger

  @type session_id :: String.t()

  @doc """
  Forwards inbound text to the project wizard when collecting answers.
  """
  @spec continue(session_id(), String.t(), keyword()) :: :not_handled | {:handled, String.t()}
  def continue(session_id, text, opts \\ []) do
    PincerPorts.Project.continue_if_collecting(session_id, text, opts)
  end

  @doc """
  Notifies the project runner that the session agent produced a response.
  """
  @spec on_agent_response(session_id(), (String.t() -> term()) | keyword()) :: term()
  def on_agent_response(session_id, send_message_or_opts) do
    PincerPorts.Project.on_agent_response(
      session_id,
      normalize_callback_opts(send_message_or_opts)
    )
  end

  @doc """
  Notifies the project runner that the session agent failed.
  """
  @spec on_agent_error(session_id(), (String.t() -> term()) | keyword()) :: term()
  def on_agent_error(session_id, send_message_or_opts) do
    PincerPorts.Project.on_agent_error(session_id, normalize_callback_opts(send_message_or_opts))
  end

  @doc """
  Attempts to kick off a collected project execution task for `session_id`.

  ## Options
  - `:ensure_session` — optional zero-arity callback ensuring the core session exists.
  - `:ensure_worker` — optional zero-arity callback ensuring the channel worker exists.
  - `:send_message` — `fn text -> any end` callback used to deliver the runner status.
  - `:dispatch` — optional `fn prompt -> result end` callback (defaults to
    `PincerPorts.Session.process_input(session_id, prompt)`).
  - `:on_start_error` — optional `fn reason -> any end` callback invoked when
    `ensure_session` or `ensure_worker` returns an error.
  - `:log_tag` — optional channel label used for warning/debug logs.
  """
  @spec kickoff(session_id(), keyword()) :: :ok
  def kickoff(session_id, opts \\ []) when is_binary(session_id) do
    case PincerPorts.Project.kickoff(session_id) do
      {:ok, kickoff} ->
        log_tag = Keyword.get(opts, :log_tag)

        with :ok <- ensure_ready(Keyword.get(opts, :ensure_session)),
             :ok <- ensure_ready(Keyword.get(opts, :ensure_worker)) do
          if send_message = Keyword.get(opts, :send_message) do
            send_message.("Project Runner: #{kickoff.status_message}")
          end

          dispatch_prompt(session_id, kickoff.prompt, opts, log_tag)
        else
          {:error, reason} ->
            if on_start_error = Keyword.get(opts, :on_start_error), do: on_start_error.(reason)

            if log_tag do
              Logger.warning("[#{log_tag}] Failed to start project execution: #{inspect(reason)}")
            end

            :ok
        end

      :not_ready ->
        :ok

      :already_started ->
        :ok

      :completed ->
        :ok
    end
  end

  defp normalize_callback_opts(fun) when is_function(fun, 1), do: [send_message: fun]
  defp normalize_callback_opts(opts) when is_list(opts), do: opts

  defp ensure_ready(nil), do: :ok

  defp ensure_ready(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  defp dispatch_prompt(session_id, prompt, opts, log_tag) when is_binary(prompt) do
    dispatch =
      Keyword.get(opts, :dispatch, fn p -> PincerPorts.Session.process_input(session_id, p) end)

    case dispatch.(prompt) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        if log_tag do
          Logger.warning("[#{log_tag}] Project task dispatch failed: #{inspect(reason)}")
        end

        :ok

      other ->
        if log_tag do
          Logger.debug("[#{log_tag}] Project task dispatch result: #{inspect(other)}")
        end

        :ok
    end
  end

  defp dispatch_prompt(_session_id, _prompt, _opts, _log_tag), do: :ok
end
