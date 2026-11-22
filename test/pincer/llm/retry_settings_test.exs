defmodule Pincer.LLM.RetrySettingsTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.RetrySettings

  test "load/1 returns defaults for an empty config" do
    assert %{
             max_retries: 5,
             initial_backoff: 2_000,
             max_backoff: 30_000,
             max_elapsed_ms: 120_000,
             jitter_ratio: 0.2
           } = RetrySettings.load([])
  end

  test "load/1 reads a keyword list" do
    settings = RetrySettings.load(max_retries: 2, initial_backoff: 10, jitter_ratio: 0.5)

    assert settings.max_retries == 2
    assert settings.initial_backoff == 10
    assert settings.jitter_ratio == 0.5
  end

  test "load/1 reads a map with atom keys" do
    settings = RetrySettings.load(%{max_backoff: 1_000, max_elapsed_ms: 5_000})

    assert settings.max_backoff == 1_000
    assert settings.max_elapsed_ms == 5_000
  end

  test "load/1 reads string-keyed entries from a plain list" do
    settings = RetrySettings.load([{"max_retries", 3}, %{"initial_backoff" => 7}])

    assert settings.max_retries == 3
    assert settings.initial_backoff == 7
  end

  test "load/1 converts integer jitter ratios to floats" do
    assert RetrySettings.load(jitter_ratio: 1).jitter_ratio === 1.0
  end

  test "load/1 replaces unusable values with defaults" do
    settings =
      RetrySettings.load(
        max_retries: 0,
        initial_backoff: -5,
        max_backoff: "fast",
        max_elapsed_ms: nil,
        jitter_ratio: 2.5
      )

    assert settings == RetrySettings.load([])
  end

  test "load/1 ignores a non-list, non-map config" do
    assert RetrySettings.load(:bogus) == RetrySettings.load([])
  end

  test "fetch/3 returns the default when the value is absent" do
    assert RetrySettings.fetch([], :max_retries, 9) == 9
    assert RetrySettings.fetch(%{}, :max_retries, 9) == 9
  end
end
