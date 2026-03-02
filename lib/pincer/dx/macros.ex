defmodule Pincer.DX.Macros do
  @moduledoc """
  Developer ergonomics macros for tests and small workflow helpers.
  """

  @doc """
  Temporarily sets an application env key during the block and restores previous state.
  """
  defmacro with_app_env(app, key, value, do: block) do
    quote do
      previous = Application.get_env(unquote(app), unquote(key), :__pincer_missing__)
      Application.put_env(unquote(app), unquote(key), unquote(value))

      try do
        unquote(block)
      after
        case previous do
          :__pincer_missing__ ->
            Application.delete_env(unquote(app), unquote(key))

          value ->
            Application.put_env(unquote(app), unquote(key), value)
        end
      end
    end
  end

  @doc """
  Extracts the payload from `{:ok, value}` or raises assertion error.
  """
  defmacro assert_ok(expr) do
    quote do
      case unquote(expr) do
        {:ok, value} ->
          value

        other ->
          raise ExUnit.AssertionError, message: "expected {:ok, value}, got: #{inspect(other)}"
      end
    end
  end
end
