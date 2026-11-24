defmodule Pincer.Channels.Feishu.Listener do
  @moduledoc """
  HTTP listener for Feishu/Lark webhook events.

  Starts Bandit with `Pincer.Channels.Feishu.Webhook`. Stops at startup when
  the webhook is disabled or the encrypt key is missing, keeping the channel
  fail-closed.
  """

  require Logger

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @spec start_link(map()) :: {:ok, pid()} | :ignore
  def start_link(config) do
    webhook = Map.get(config, "webhook", %{})
    encrypt_key_env = Map.get(webhook, "encrypt_key_env", "FEISHU_ENCRYPT_KEY")
    encrypt_key = System.get_env(encrypt_key_env)

    cond do
      Map.get(webhook, "enabled") != true ->
        :ignore

      encrypt_key in [nil, ""] ->
        Logger.warning("#{encrypt_key_env} not set; Feishu webhook listener disabled.")
        :ignore

      true ->
        with {:ok, ip} <- parse_bind(Map.get(webhook, "bind", "127.0.0.1")),
             {:ok, port} <- parse_port(Map.get(webhook, "port", 4010)) do
          path = Map.get(webhook, "path", "/webhooks/feishu")

          Bandit.start_link(
            plug: {Pincer.Channels.Feishu.Webhook, path: path},
            ip: ip,
            port: port
          )
        else
          {:error, reason} ->
            Logger.error("[FEISHU] invalid webhook listener config: #{inspect(reason)}")
            :ignore
        end
    end
  end

  defp parse_bind(bind) when is_binary(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, {:invalid_bind, bind}}
    end
  end

  defp parse_bind(_bind), do: {:error, :invalid_bind}

  defp parse_port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  defp parse_port(_port), do: {:error, :invalid_port}
end
