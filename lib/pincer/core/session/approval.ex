defmodule Pincer.Core.Session.Approval do
  @moduledoc """
  Pure policy helpers for session tool approvals, cancellation commands, and
  time-boxed auto-approval windows.
  """

  @approve_tokens ~w(aprovo sim yes approve ok s y)
  @reject_tokens ["rejeito", "não", "nao", "no", "reject", "n"]
  @cancel_tokens ~w(para stop cancel cancela /stop /cancel)

  @doc """
  Parses user text into an approval decision (`:approved`, `:rejected`, or `:unknown`).
  """
  @spec parse_decision(String.t()) :: :approved | :rejected | :unknown
  def parse_decision(text) when is_binary(text) do
    normalized = normalize(text)

    cond do
      normalized in @approve_tokens -> :approved
      normalized in @reject_tokens -> :rejected
      true -> :unknown
    end
  end

  def parse_decision(_), do: :unknown

  @doc """
  Returns `true` when user text represents an execution interruption/cancel command.
  """
  @spec cancel_command?(String.t()) :: boolean()
  def cancel_command?(text) when is_binary(text), do: normalize(text) in @cancel_tokens
  def cancel_command?(_), do: false

  @doc """
  Returns `true` when `until` is a future `DateTime` relative to `now`.
  """
  @spec auto_approve_active?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def auto_approve_active?(until, now \\ DateTime.utc_now())
  def auto_approve_active?(nil, _now), do: false

  def auto_approve_active?(%DateTime{} = until, %DateTime{} = now) do
    DateTime.compare(until, now) == :gt
  end

  @doc """
  Decides whether an incoming tool approval request should be auto-approved or
  stored as pending user confirmation.
  """
  @spec handle_request(String.t(), String.t(), DateTime.t() | nil, DateTime.t()) ::
          {:auto_approved, String.t()} | {:pending, {String.t(), String.t()}}
  def handle_request(call_id, command, auto_approve_until, now \\ DateTime.utc_now()) do
    if auto_approve_active?(auto_approve_until, now) do
      {:auto_approved, call_id}
    else
      {:pending, {call_id, command}}
    end
  end

  @doc """
  Computes the new auto-approve expiration timestamp and determines whether any
  pending approval should be approved immediately.
  """
  @spec enable_auto_approve({String.t(), String.t()} | nil, integer(), DateTime.t()) ::
          {DateTime.t(), {String.t(), String.t()} | nil, {:auto_approve, String.t()} | :noop}
  def enable_auto_approve(pending_approval, duration_seconds, now \\ DateTime.utc_now()) do
    until = DateTime.add(now, duration_seconds, :second)

    case pending_approval do
      {call_id, _command} when duration_seconds > 0 ->
        {until, nil, {:auto_approve, call_id}}

      _other ->
        cleared_pending = if duration_seconds > 0, do: nil, else: pending_approval
        {until, cleared_pending, :noop}
    end
  end

  @doc """
  Resolves a user reply against a pending `{call_id, command}` pair.
  """
  @spec resolve_pending({String.t(), String.t()}, String.t()) ::
          {:decided, String.t(), :approved | :rejected}
          | {:prompt_again, {String.t(), String.t()}}
  def resolve_pending({call_id, _command} = pending, text) do
    case parse_decision(text) do
      decision when decision in [:approved, :rejected] ->
        {:decided, call_id, decision}

      :unknown ->
        {:prompt_again, pending}
    end
  end

  defp normalize(text), do: text |> String.downcase() |> String.trim()
end
