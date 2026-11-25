defmodule Pincer.Channels.Shared.Pairing do
  @moduledoc """
  Shared DM access policy checks and `/pair` approval workflow across channel
  adapters.
  """

  @default_usage_message "Uso: /pair <codigo>. Solicite o codigo de pairing ao operador."
  @default_dm_only_message "Pairing so pode ser concluido em DM privada."

  @doc """
  Returns `true` when `text` starts with the `/pair` command (case-insensitive).
  """
  @spec pair_command?(term()) :: boolean()
  def pair_command?(text) when is_binary(text) do
    text |> String.trim() |> String.downcase() |> String.starts_with?("/pair")
  end

  def pair_command?(_), do: false

  @doc """
  Extracts and trims the pairing code from either raw code text or a `/pair <code>`
  command string.
  """
  @spec extract_code(term()) :: String.t()
  def extract_code(nil), do: ""

  def extract_code(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.starts_with?(String.downcase(trimmed), "/pair") do
      trimmed
      |> String.slice(5..-1//1)
      |> String.trim()
    else
      trimmed
    end
  end

  def extract_code(other), do: other |> to_string() |> extract_code()

  @doc """
  Checks DM access through `PincerPorts.ChannelPolicy.allow?(:dm_access, ...)`.

  Returns `:allow` immediately when `is_dm: false`.
  """
  @spec authorize_dm(atom(), term(), map(), keyword()) :: :allow | {:deny, String.t()}
  def authorize_dm(channel, sender_id, config, opts \\ [])
      when is_atom(channel) and is_map(config) and is_list(opts) do
    if Keyword.get(opts, :is_dm, true) do
      policy_module = Keyword.get(opts, :policy_module, PincerPorts.ChannelPolicy)

      case policy_module.allow?(:dm_access, %{
             channel: channel,
             sender_id: sender_id,
             config: config
           }) do
        {:allow, _meta} -> :allow
        {:deny, %{user_message: message}} -> {:deny, message}
      end
    else
      :allow
    end
  end

  @doc """
  Approves a `/pair` code for a sender via `PincerPorts.ChannelPolicy` and
  returns a standardized `{:ok, message}` or `{:error, reason, message}` tuple.

  ## Options

    - `:is_dm` (default `true`) - rejects non-DM contexts with `:dm_only`.
    - `:dm_only_message` - custom message when `:is_dm` is `false`.
    - `:usage_message` - custom usage hint when code is missing.
    - `:policy_module` (default `PincerPorts.ChannelPolicy`).
    - `:on_approved` - optional 0-arity callback executed upon `:ok`.
    - `:include_bound_agent` (default `false`) - includes `bound_agent_id/2` details when set.
    - `:format_bound_agent` - 1-arity formatter for the bound agent clause.
  """
  @spec approve(atom(), term(), term(), keyword()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def approve(channel, sender_id, code_input, opts \\ [])
      when is_atom(channel) and is_list(opts) do
    is_dm? = Keyword.get(opts, :is_dm, true)
    dm_only_message = Keyword.get(opts, :dm_only_message, @default_dm_only_message)
    usage_message = Keyword.get(opts, :usage_message, @default_usage_message)
    policy_module = Keyword.get(opts, :policy_module, PincerPorts.ChannelPolicy)
    code = extract_code(code_input)

    cond do
      not is_dm? ->
        {:error, :dm_only, dm_only_message}

      code == "" ->
        {:error, :missing_code, usage_message}

      true ->
        case policy_module.approve_code(channel, sender_id, code) do
          :ok ->
            run_on_approved(Keyword.get(opts, :on_approved))
            {:ok, success_message(policy_module, channel, sender_id, opts)}

          {:error, reason} ->
            {:error, reason, error_message(reason)}
        end
    end
  end

  @doc """
  Maps pairing policy failure reasons to consistent user-facing messages.
  """
  @spec error_message(atom()) :: String.t()
  def error_message(:not_pending) do
    "Nenhum pairing pendente para este usuario. Solicite um novo codigo ao operador."
  end

  def error_message(:expired) do
    "Codigo de pairing expirado. Solicite um novo codigo ao operador."
  end

  def error_message(:invalid_code) do
    "Codigo de pairing invalido. Revise o codigo e tente novamente."
  end

  def error_message(:attempts_exceeded) do
    "Tentativas excedidas para este codigo. Solicite um novo codigo ao operador."
  end

  def error_message(_other) do
    "Nao foi possivel concluir o pairing. Solicite um novo codigo ao operador."
  end

  defp run_on_approved(fun) when is_function(fun, 0), do: fun.()
  defp run_on_approved(_), do: :ok

  defp success_message(policy_module, channel, sender_id, opts) do
    include_bound_agent? = Keyword.get(opts, :include_bound_agent, false)

    if include_bound_agent? do
      case policy_module.bound_agent_id(channel, sender_id) do
        nil ->
          "Pairing concluido com sucesso. Agora sua DM esta autorizada."

        bound_agent_id ->
          formatter =
            Keyword.get(opts, :format_bound_agent, fn id ->
              "Esta DM agora aponta para o agente #{id}."
            end)

          "Pairing concluido com sucesso. #{formatter.(bound_agent_id)}"
      end
    else
      "Pairing concluido com sucesso. Agora sua DM esta autorizada."
    end
  end
end
