defmodule Pincer.Adapters.Sandbox.Runtime do
  @moduledoc """
  Runtime and policy helpers shared by `Pincer.Ports.Sandbox` adapters.

  Provides backend configuration lookup, environment variable sanitization,
  and bounded task execution with brutal-kill timeout enforcement.
  """

  @env_key_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @forbidden_env_keys MapSet.new([
                        "LD_PRELOAD",
                        "LD_LIBRARY_PATH",
                        "LD_AUDIT",
                        "LD_ORIGIN_PATH",
                        "DYLD_INSERT_LIBRARIES",
                        "DYLD_LIBRARY_PATH",
                        "DYLD_FRAMEWORK_PATH",
                        "BASH_ENV",
                        "ENV",
                        "IFS"
                      ])

  @doc """
  Returns backend-specific configuration merged from `:pincer, :sandbox`.
  """
  @spec backend_config(atom()) :: keyword()
  def backend_config(backend) when is_atom(backend) do
    cfg = Application.get_env(:pincer, :sandbox, %{}) || %{}

    raw =
      Map.get(cfg, backend) ||
        Map.get(cfg, Atom.to_string(backend)) ||
        %{}

    cond do
      is_list(raw) ->
        raw

      is_map(raw) ->
        Enum.reduce(raw, [], fn
          {k, v}, acc when is_atom(k) -> Keyword.put(acc, k, v)
          {k, v}, acc when is_binary(k) -> safe_kw_put(acc, k, v)
          _, acc -> acc
        end)

      true ->
        []
    end
  end

  @doc """
  Executes `fun` inside a linked worker task enforcing `timeout_ms`.

  Terminates the task brutally on expiry and returns `{:error, :timeout}`.
  """
  @spec run_with_timeout((-> term()), non_neg_integer() | :infinity | nil) ::
          {:ok, term()} | {:error, :timeout | {:task_exit, term()}}
  def run_with_timeout(fun, timeout_ms \\ 30_000) when is_function(fun, 0) do
    if is_integer(timeout_ms) and timeout_ms > 0 do
      task = Task.async(fun)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> {:ok, result}
        {:exit, reason} -> {:error, {:task_exit, reason}}
        nil -> {:error, :timeout}
      end
    else
      {:ok, fun.()}
    end
  end

  @doc """
  Validates and normalizes environment variables passed into a sandbox execution.

  Rejects loader-hijack / shell-startup variables (`LD_*`, `DYLD_*`, `BASH_ENV`,
  `ENV`, `IFS`), invalid identifier keys, and non-binary entries.
  """
  @spec validate_env(nil | map() | [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def validate_env(nil), do: {:ok, []}

  def validate_env(env) when is_map(env) do
    env
    |> Map.to_list()
    |> validate_env()
  end

  def validate_env(env) when is_list(env) do
    Enum.reduce_while(env, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        cond do
          not Regex.match?(@env_key_regex, key) ->
            {:halt, {:error, {:invalid_env_key, key}}}

          forbidden_env_key?(key) ->
            {:halt, {:error, {:forbidden_env, key}}}

          true ->
            {:cont, {:ok, [{key, value} | acc]}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_env_entry}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def validate_env(_other), do: {:error, :invalid_env_entry}

  defp safe_kw_put(acc, key_str, val) do
    Keyword.put(acc, String.to_existing_atom(key_str), val)
  rescue
    ArgumentError -> acc
  end

  defp forbidden_env_key?(key) do
    upper = String.upcase(key)
    MapSet.member?(@forbidden_env_keys, upper) or String.starts_with?(upper, "DYLD_")
  end
end
