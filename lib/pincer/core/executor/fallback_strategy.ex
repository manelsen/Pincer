defmodule Pincer.Core.Executor.FallbackStrategy do
  @moduledoc """
  Recovers a turn when the streaming call fails by re-issuing the request as a
  single-shot chat completion.

  The recovery decision itself is pure (`Policy.recover(:stream_fallback, ...)`):
  rebuild a pruned prompt on context overflow, drop tools when the provider
  rejects tool calling, keep everything otherwise. What cannot be pure is the
  continuation: a successful fallback response has to re-enter the executor's
  message finalisation, which may itself resume the tool loop. That re-entry is
  supplied as a callback, so this module never depends on `Pincer.Core.Executor`
  at compile time.
  """

  require Logger

  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Policy
  alias PincerPorts.Structs.Usage

  @type outcome ::
          {:ok, [map()], String.t(), Usage.t() | nil, Ctx.t()} | {:error, term(), Ctx.t()}

  @type prepare_history :: ([map()], Ctx.t(), keyword() -> {[map()], Ctx.t()})
  @type finalize ::
          (map(), [map()], [map()], non_neg_integer(), Ctx.t(), Usage.t() | nil, keyword() ->
             outcome)

  @typedoc """
  `:prepare_history` rebuilds the prompt with pruning limits;
  `:finalize` re-enters the executor's message finalisation.
  """
  @type callbacks :: [prepare_history: prepare_history(), finalize: finalize()]

  @doc """
  Runs the chat-completion fallback for a failed streaming call.

  `logical_history` and `prompt_history` are forwarded to the finaliser
  unchanged; only the request sent to the provider is rebuilt.
  """
  @spec run(term(), [map()], [map()], non_neg_integer(), Ctx.t(), keyword(), [map()], callbacks()) ::
          outcome()
  def run(
        reason,
        logical_history,
        prompt_history,
        depth,
        %Ctx{} = ctx,
        client_opts,
        tools_spec,
        callbacks
      ) do
    Logger.warning("[EXECUTOR] Falling back to chat completion. Reason: #{inspect(reason)}")
    ctx = Ctx.record_trace(ctx, :policy, "fallback_chat_completion", %{reason: inspect(reason)})

    {fallback_history, chat_opts, ctx} =
      build_request(
        reason,
        logical_history,
        prompt_history,
        ctx,
        client_opts,
        tools_spec,
        Keyword.fetch!(callbacks, :prepare_history)
      )

    case ctx.deps.llm_client.chat_completion(fallback_history, chat_opts) do
      {:ok, assistant_msg, usage} ->
        ctx = Ctx.record_trace(ctx, :llm, "chat_completion_invoked", %{fallback: true})

        callbacks
        |> Keyword.fetch!(:finalize)
        |> apply_finalizer(assistant_msg, logical_history, prompt_history, depth, ctx, usage)

      {:error, err_reason} ->
        Logger.error("[EXECUTOR] Fallback chat completion failed: #{inspect(err_reason)}")

        ctx =
          Ctx.record_trace(ctx, :error, "fallback_chat_completion_failed", %{
            reason: inspect(err_reason)
          })

        {:error, err_reason, ctx}
    end
  end

  @doc """
  Decides how to reshape the request for the fallback attempt.

  Returns `{history, client_opts, ctx}` where `history` is the prompt to send.
  """
  @spec build_request(term(), [map()], [map()], Ctx.t(), keyword(), [map()], prepare_history()) ::
          {[map()], keyword(), Ctx.t()}
  def build_request(
        reason,
        logical_history,
        prompt_history,
        %Ctx{} = ctx,
        client_opts,
        tools_spec,
        prepare_history
      )
      when is_function(prepare_history, 3) do
    case Policy.recover(:stream_fallback, %{reason: reason, tools_present?: tools_spec != []}) do
      {:rebuild_prompt, %{safe_limit_scale: safe_limit_scale, drop_tools?: drop_tools?}} ->
        Logger.warning(
          "[EXECUTOR] Context overflow detected. Rebuilding fallback prompt with scale=#{safe_limit_scale} and drop_tools?=#{drop_tools?}."
        )

        {fallback_history, ctx} =
          prepare_history.(logical_history, ctx, safe_limit_scale: safe_limit_scale)

        fallback_opts = if drop_tools?, do: client_opts, else: [tools: tools_spec] ++ client_opts
        {fallback_history, fallback_opts, ctx}

      :drop_tools ->
        Logger.warning(
          "[EXECUTOR] Provider/model does not support tool calling. Retrying fallback chat completion without tools."
        )

        {prompt_history, client_opts, ctx}

      :keep_tools ->
        {prompt_history, [tools: tools_spec] ++ client_opts, ctx}
    end
  end

  defp apply_finalizer(
         finalize,
         assistant_msg,
         logical_history,
         prompt_history,
         depth,
         ctx,
         usage
       ) do
    finalize.(assistant_msg, logical_history, prompt_history, depth, ctx, usage, [])
  end
end
