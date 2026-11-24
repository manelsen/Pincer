defmodule Pincer.Channels.DingTalk.Listener do
  @moduledoc """
  HTTP listener for DingTalk robot event subscriptions.

  Starts Bandit with `Pincer.Channels.DingTalk.Webhook`. Disabled unless the
  webhook is enabled and the signing secret is configured.
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
    secret_env = Map.get(config, "signing_secret_env", "DINGTALK_SIGNING_SECRET")
    secret = System.get_env(secret_env)

    cond do
      Map.get(webhook, "enabled") != true ->
        :ignore

      secret in [nil, ""] ->
        Logger.warning("#{secret_env} not set; DingTalk webhook listener disabled.")
        :ignore

      true ->
        with {:ok, ip} <- parse_bind(Map.get(webhook, "bind", "127.0.0.1")),
             {:ok, port} <- parse_port(Map.get(webhook, "port", 4012)) do
          Bandit.start_link(
            plug: {Pincer.Channels.DingTalk.Webhook, []},
            ip: ip,
            port: port
          )
        else
          {:error, reason} ->
            Logger.error("[DINGTALK] invalid webhook listener config: #{inspect(reason)}")
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
