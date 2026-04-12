defmodule Pincer.Channels.Shared.TokenCache do
  @moduledoc """
  A GenServer that caches OAuth2 access tokens with automatic refresh.

  Stores `{token, expires_at}` and refreshes the token before it expires,
  using a 60-second safety margin. Handles concurrent requests without
  stampede -- when a refresh is in progress, subsequent callers wait for
  the same refresh result rather than triggering additional fetches.

  ## Usage

      # Start with a fetch function that returns {:ok, token, expires_at}
      # or {:error, reason}
      {:ok, pid} = TokenCache.start_link(
        name: :my_token_cache,
        fetch_fn: fn ->
          case MyApp.OAuth.get_token() do
            %{"access_token" => t, "expires_in" => e} ->
              {:ok, t, System.system_time(:second) + e}
            error ->
              {:error, error}
          end
        end
      )

      # Get the current token (refreshes if expired)
      {:ok, token} = TokenCache.get_token(:my_token_cache)
  """

  use GenServer
  require Logger

  @safety_margin_seconds 60

  defstruct [:token, :expires_at, :fetch_fn, :last_error, waiters: []]

  # Client API

  @doc """
  Starts the TokenCache GenServer.

  ## Options

    * `:name` -- registered name for the GenServer (required)
    * `:fetch_fn` -- function that returns `{:ok, token, expires_at}` or `{:error, reason}` (required)
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the current token, refreshing if expired or near-expiry.

  Handles concurrent callers: if a refresh is already in progress,
  waits for that refresh rather than triggering a new one (stampede protection).

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  def get_token(name) do
    GenServer.call(name, :get_token, 30_000)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    fetch_fn = Keyword.fetch!(opts, :fetch_fn)

    case fetch_fn.() do
      {:ok, token, expires_at} ->
        {:ok, %__MODULE__{token: token, expires_at: expires_at, fetch_fn: fetch_fn}}

      {:error, reason} ->
        # Start anyway with empty cache; next get_token will retry
        {:ok, %__MODULE__{fetch_fn: fetch_fn, last_error: reason}}
    end
  end

  @impl true
  def handle_call(:get_token, from, %{waiters: [_ | _]} = state) do
    # A refresh is already in progress. Queue this caller.
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:get_token, from, state) do
    if fresh?(state) do
      {:reply, {:ok, state.token}, state}
    else
      # Kick off async refresh and queue the caller
      spawn_refresh(state)
      {:noreply, %{state | waiters: [from]}}
    end
  end

  @impl true
  def handle_info({:refresh_result, result}, state) do
    case result do
      {:ok, new_token, new_expires_at} ->
        reply_to_all(state.waiters, {:ok, new_token})

        {:noreply,
         %{state | token: new_token, expires_at: new_expires_at, last_error: nil, waiters: []}}

      {:error, reason} ->
        reply_to_all(state.waiters, {:error, reason})
        {:noreply, %{state | last_error: reason, waiters: []}}
    end
  end

  # Helpers

  defp fresh?(%{token: nil}), do: false
  defp fresh?(%{expires_at: nil}), do: false

  defp fresh?(%{expires_at: expires_at}) do
    now = System.system_time(:second)
    expires_at - now > @safety_margin_seconds
  end

  defp spawn_refresh(state) do
    parent = self()
    fetch_fn = state.fetch_fn

    Task.start(fn ->
      result = fetch_fn.()
      send(parent, {:refresh_result, result})
    end)
  end

  defp reply_to_all([], _reply), do: :ok

  defp reply_to_all(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end
end
