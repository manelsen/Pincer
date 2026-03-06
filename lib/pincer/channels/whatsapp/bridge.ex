defmodule Pincer.Channels.WhatsApp.Bridge do
  @moduledoc """
  Behaviour for WhatsApp transport bridge adapters.

  The default adapter uses an external Node process (Baileys) over JSONL.
  """

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_message(pid(), String.t(), String.t()) :: :ok | {:error, term()}
end

defmodule Pincer.Channels.WhatsApp.Bridge.Adapter do
  @moduledoc """
  Default WhatsApp bridge adapter backed by an external process via Port.

  Protocol:
  - Outbound to bridge: JSON line with `action` payloads
  - Inbound from bridge: JSON line events forwarded to channel process
  """

  use GenServer
  @behaviour Pincer.Channels.WhatsApp.Bridge
  require Logger

  @default_command "./infrastructure/whatsapp/whatsapp_bridge"
  @default_args []

  @impl true
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def send_message(pid, chat_id, text)
      when is_pid(pid) and is_binary(chat_id) and is_binary(text) do
    GenServer.call(pid, {:send_message, chat_id, text})
  end

  @doc """
  Decodes newline-delimited JSON events while preserving an incomplete tail.
  """
  @spec decode_events(String.t(), String.t()) :: {[map()], String.t()}
  def decode_events(buffer, new_data) when is_binary(buffer) and is_binary(new_data) do
    full = buffer <> new_data
    chunks = String.split(full, "\n")
    {complete, [tail]} = Enum.split(chunks, -1)

    events =
      complete
      |> Enum.reduce([], fn line, acc ->
        case String.trim(line) do
          "" ->
            acc

          encoded ->
            case Jason.decode(encoded) do
              {:ok, event} when is_map(event) -> [event | acc]
              _ -> acc
            end
        end
      end)
      |> Enum.reverse()

    {events, tail}
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    config = Keyword.get(opts, :config, %{})
    bridge_config = normalize_bridge_config(config)
    command = bridge_config.command
    args = bridge_config.args

    with executable when is_binary(executable) <- System.find_executable(command) || command,
         true <- executable != "" do
      env = to_port_env(bridge_config.env)

      port_opts =
        [:binary, :exit_status, :stderr_to_stdout, args: args] ++
          maybe_env_option(env) ++ maybe_cd_option(bridge_config.cwd)

      port = Port.open({:spawn_executable, executable}, port_opts)

      {:ok,
       %{
         owner: owner,
         port: port,
         buffer: ""
       }}
    else
      _ ->
        {:stop, {:bridge_command_not_found, command}}
    end
  rescue
    error ->
      {:stop, {:bridge_start_failed, error}}
  end

  @impl true
  def handle_call({:send_message, chat_id, text}, _from, state) do
    payload = %{"action" => "send_message", "chat_id" => chat_id, "text" => text}
    encoded = Jason.encode!(payload) <> "\n"

    reply =
      case Port.command(state.port, encoded) do
        true -> :ok
        false -> {:error, :bridge_not_available}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {events, tail} = decode_events(state.buffer, data)

    Enum.each(events, fn event ->
      send(state.owner, {:whatsapp_bridge_event, event})
    end)

    {:noreply, %{state | buffer: tail}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:whatsapp_bridge_exit, status})
    {:stop, {:bridge_exit, status}, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("[WHATSAPP] Ignoring bridge message: #{inspect(message)}")
    {:noreply, state}
  end

  defp normalize_bridge_config(config) when is_map(config) do
    bridge_cfg = read_map(config, "bridge", %{})
    command = read_map(bridge_cfg, "command", @default_command)
    args = normalize_args(read_map(bridge_cfg, "args", @default_args))
    cwd = read_map(bridge_cfg, "cwd", nil)
    auth_dir = read_map(bridge_cfg, "auth_dir", nil)
    qr_ascii = to_env_bool(read_map(bridge_cfg, "qr_ascii", true), true)
    qr_ascii_small = to_env_bool(read_map(bridge_cfg, "qr_ascii_small", true), true)
    pairing_phone = normalize_phone(read_map(bridge_cfg, "pairing_phone", nil))
    custom_env = normalize_env(read_map(bridge_cfg, "env", nil))

    base_env =
      []
      |> maybe_put_env("WA_AUTH_DIR", auth_dir)
      |> maybe_put_env("WA_QR_ASCII", bool_to_env(qr_ascii))
      |> maybe_put_env("WA_QR_ASCII_SMALL", bool_to_env(qr_ascii_small))
      |> maybe_put_env("WA_PAIRING_PHONE", pairing_phone)

    env = merge_env(base_env, custom_env)

    %{
      command: to_string(command),
      args: args,
      cwd: normalize_cwd(cwd),
      env: env
    }
  end

  defp normalize_args(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_args(_), do: @default_args

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.reduce(env, [], fn
      {k, v}, acc ->
        [{to_string(k), to_string(v)} | acc]

      entry, acc when is_binary(entry) ->
        case String.split(entry, "=", parts: 2) do
          [k, v] when k != "" -> [{k, v} | acc]
          _ -> acc
        end

      _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_env(_), do: []

  defp normalize_cwd(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      cwd -> cwd
    end
  end

  defp normalize_cwd(_), do: nil

  @doc false
  @spec to_port_env(list()) :: [{charlist(), charlist()}]
  def to_port_env(env_entries) when is_list(env_entries) do
    env_entries
    |> Enum.reduce([], fn
      {key, value}, acc ->
        case {to_port_env_token(key), to_port_env_token(value)} do
          {k, v} when is_list(k) and is_list(v) and k != [] -> [{k, v} | acc]
          _ -> acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  def to_port_env(_), do: []

  defp maybe_cd_option(nil), do: []
  defp maybe_cd_option(cwd), do: [cd: cwd]
  defp maybe_env_option([]), do: []
  defp maybe_env_option(env), do: [env: env]

  defp maybe_put_env(env, _key, value) when value in [nil, ""], do: env
  defp maybe_put_env(env, key, value), do: env ++ [{to_string(key), to_string(value)}]

  defp merge_env(base_env, override_env) do
    base_env
    |> Enum.into(%{})
    |> Map.merge(Enum.into(override_env, %{}))
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp normalize_phone(value) when is_binary(value) do
    value
    |> String.replace(~r/\D+/, "")
    |> String.trim()
  end

  defp normalize_phone(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> normalize_phone()
  end

  defp normalize_phone(_), do: nil

  defp to_env_bool(nil, default), do: default
  defp to_env_bool(value, _default) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp to_env_bool(value, _default) when value in [false, "false", "0", 0, "no", "off"], do: false
  defp to_env_bool(_value, default), do: default

  defp bool_to_env(true), do: "true"
  defp bool_to_env(false), do: "false"

  defp to_port_env_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.to_charlist(text)
    end
  end

  defp to_port_env_token(value) when is_atom(value),
    do: value |> Atom.to_string() |> to_port_env_token()

  defp to_port_env_token(value) when is_integer(value),
    do: value |> Integer.to_string() |> to_port_env_token()

  defp to_port_env_token(value) when is_list(value), do: value
  defp to_port_env_token(_), do: nil

  defp read_map(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {k, value} when is_atom(k) -> if Atom.to_string(k) == key, do: value, else: nil
        _ -> nil
      end) ||
      default
  end

  defp read_map(_map, _key, default), do: default
end
