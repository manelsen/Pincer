defmodule Pincer.Channels.Telegram.ResponseEnvelopeTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Telegram.ResponseEnvelope
  alias PincerPorts.Structs.Usage

  test "builds telegram final text with token usage footer from Usage struct" do
    usage = %Usage{prompt_tokens: 12, completion_tokens: 34, total_tokens: 46}

    assert ResponseEnvelope.build("Resposta", usage, "tokens") ==
             "Resposta\n\n<i>📊 12 in · 34 out</i>"
  end

  test "builds telegram final text with full usage footer" do
    usage = %Usage{prompt_tokens: 12, completion_tokens: 34, total_tokens: 46}

    assert ResponseEnvelope.build("Resposta", usage, "full") ==
             "Resposta\n\n<i>📊 total: 46 tokens</i>"
  end

  test "accepts legacy usage map and normalizes it once" do
    usage = %{"prompt_tokens" => 12, "completion_tokens" => 34}

    assert ResponseEnvelope.build("Resposta", usage, "tokens") ==
             "Resposta\n\n<i>📊 12 in · 34 out</i>"
  end

  test "omits usage footer when usage is nil or usage_display is off" do
    usage = %Usage{prompt_tokens: 12, completion_tokens: 34, total_tokens: 46}

    assert ResponseEnvelope.build("Resposta", nil, "tokens") == "Resposta"
    assert ResponseEnvelope.build("Resposta", usage, "off") == "Resposta"
    assert ResponseEnvelope.build("Resposta", usage, nil) == "Resposta"
  end

  test "delivery options expose telegram reasoning visibility flag" do
    assert ResponseEnvelope.delivery_options(%{reasoning_visible: true}) ==
             [skip_reasoning_strip: true]

    assert ResponseEnvelope.delivery_options(%{reasoning_visible: false}) == []
    assert ResponseEnvelope.delivery_options(%{}) == []
  end

  test "build returns empty string when text and usage footer are absent" do
    assert ResponseEnvelope.build(nil, nil, "off") == ""
  end
end
