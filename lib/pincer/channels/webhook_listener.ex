defmodule Pincer.Channels.Webhook.Listener do
  @moduledoc """
  Supervises the HTTP listener for the webhook channel.

  The listener runs a Bandit server whose plug is `Pincer.Channels.Webhook.Plug`.
  It resolves the authentication token through
  `Pincer.Channels.Webhook.configured_token/1` and returns `:ignore` when the
  token is not configured, so a misconfigured webhook never binds a port.

  The configuration map is the same map the channel receives. Both string and
  atom keys are supported:

    * `:port` - HTTP port, defaults to `4000`; `0` selects an ephemeral port
    * `:bind` - bind address, defaults to `"127.0.0.1"`; invalid values raise
    * `:path` - POST path, defaults to `"/webhook/message"` (`"/webhook"` is
      accepted as an alias)
    * `:max_body_bytes` - maximum request body size, defaults to `1_048_576`
    * `:rate_limit_per_minute` - maximum requests per client IP per 60-second
      window, defaults to `60`; `0` disables limiting
    * `:token_env` - name of the environment variable holding the token
  """

  use Supervisor

  require Logger

  @default_port 4000
  @default_bind "127.0.0.1"
  @default_path "/webhook/message"
  @default_max_body_bytes 1_048_576
  @default_rate_limit_per_minute 60

  @doc """
  Starts the webhook HTTP listener.

  Returns `:ignore` when `token_env` is unset, empty, or not usable.
  """
  @spec start_link(map()) :: Supervisor.on_start()
  def start_link(config) when is_map(config) do
    case Pincer.Channels.Webhook.configured_token(config) do
      {:ok, token} when is_binary(token) and token != "" ->
        Supervisor.start_link(__MODULE__, build_config(config, token))

      _ ->
        Logger.warning("[WEBHOOK] token_env is missing or empty; listener ignored.")
        :ignore
    end
  end

  @impl Supervisor
  def init(config) do
    {rate_limiter, limiter_children} = rate_limiter(config)

    plug_opts = [
      token: config.token,
      path: config.path,
      max_body_bytes: config.max_body_bytes,
      rate_limiter: rate_limiter
    ]

    children =
      limiter_children ++
        [
          {Bandit,
           plug: {Pincer.Channels.Webhook.Plug, plug_opts},
           scheme: :http,
           ip: config.ip,
           port: config.port}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp rate_limiter(%{rate_limit_per_minute: limit}) when limit > 0 do
    {Pincer.Channels.Webhook.RateLimiter, [{Pincer.Channels.Webhook.RateLimiter, limit: limit}]}
  end

  defp rate_limiter(_config), do: {nil, []}

  defp build_config(config, token) do
    %{
      port: parse_port(read_config(config, "port", @default_port)),
      ip: parse_bind(read_config(config, "bind", @default_bind)),
      path: normalize_path(read_config(config, "path", @default_path)),
      max_body_bytes:
        parse_max_body_bytes(read_config(config, "max_body_bytes", @default_max_body_bytes)),
      rate_limit_per_minute:
        parse_rate_limit_per_minute(
          read_config(config, "rate_limit_per_minute", @default_rate_limit_per_minute)
        ),
      token: token
    }
  end

  defp parse_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: port

  defp parse_port(port) do
    raise ArgumentError,
          "invalid webhook port #{inspect(port)}; expected an integer in 0..65535"
  end

  defp parse_bind(bind) when is_binary(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, ip} ->
        ip

      {:error, _reason} ->
        raise ArgumentError, "invalid webhook bind address #{inspect(bind)}"
    end
  end

  defp parse_bind(bind) do
    raise ArgumentError, "invalid webhook bind #{inspect(bind)}; expected an IP address string"
  end

  defp parse_max_body_bytes(value) when is_integer(value) and value > 0, do: value

  defp parse_max_body_bytes(value) do
    raise ArgumentError,
          "invalid webhook max_body_bytes #{inspect(value)}; expected a positive integer"
  end

  defp parse_rate_limit_per_minute(value) when is_integer(value) and value >= 0, do: value

  defp parse_rate_limit_per_minute(value) do
    Logger.warning(
      "[WEBHOOK] invalid webhook rate_limit_per_minute #{inspect(value)}; " <>
        "using default #{@default_rate_limit_per_minute}"
    )

    @default_rate_limit_per_minute
  end

  defp normalize_path(path) when is_binary(path) and path != "", do: path
  defp normalize_path(_path), do: @default_path

  defp read_config(config, key, default) when is_map(config) do
    Map.get(config, key) || Map.get(config, String.to_atom(key)) || default
  end
end
