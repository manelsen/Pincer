defmodule Pincer.Architecture.WebhookPackageTest do
  use ExUnit.Case, async: true

  test "webhook HTTP plug, listener, and rate limiter reside in pincer_webhook" do
    refute File.exists?("lib/pincer/channels/webhook_plug.ex")
    refute File.exists?("lib/pincer/channels/webhook_listener.ex")
    refute File.exists?("lib/pincer/channels/webhook_rate_limiter.ex")

    assert File.exists?("packages/pincer_webhook/lib/pincer/channels/webhook/plug.ex")
    assert File.exists?("packages/pincer_webhook/lib/pincer/channels/webhook/listener.ex")
    assert File.exists?("packages/pincer_webhook/lib/pincer/channels/webhook/rate_limiter.ex")
  end

  test "Channel Factory uses polymorphic extra_child_specs without hardcoding Webhook" do
    factory_source = File.read!("lib/pincer/channels/factory.ex")

    refute factory_source =~ "Pincer.Channels.Webhook"
    assert factory_source =~ "extra_child_specs"
    cfg = %{"enabled" => true, "token_env" => "TEST_TOKEN"}

    assert Pincer.Channels.Webhook.extra_child_specs(cfg) == [
             {Pincer.Channels.Webhook.Listener, cfg}
           ]
  end
end
