defmodule Pincer.Core.ResponseEnvelopeTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ResponseEnvelope

  test "builds telegram final text with token usage footer" do
    usage = %{"prompt_tokens" => 12, "completion_tokens" => 34}

    assert ResponseEnvelope.build(:telegram, "Resposta", usage, "tokens") ==
             "Resposta\n\n<i>📊 12 in · 34 out</i>"
  end

  test "builds telegram final text with full usage footer" do
    usage = %{"prompt_tokens" => 12, "completion_tokens" => 34}

    assert ResponseEnvelope.build(:telegram, "Resposta", usage, "full") ==
             "Resposta\n\n<i>📊 total: 46 tokens</i>"
  end

  test "discord keeps final text unchanged regardless of usage display" do
    usage = %{"prompt_tokens" => 12, "completion_tokens" => 34}

    assert ResponseEnvelope.build(:discord, "Resposta", usage, "tokens") == "Resposta"
  end

  test "delivery options expose telegram reasoning visibility flag" do
    assert ResponseEnvelope.delivery_options(:telegram, %{reasoning_visible: true}) ==
             [skip_reasoning_strip: true]

    assert ResponseEnvelope.delivery_options(:telegram, %{reasoning_visible: false}) == []
    assert ResponseEnvelope.delivery_options(:telegram, %{}) == []
    assert ResponseEnvelope.delivery_options(:discord, %{reasoning_visible: true}) == []
  end

  test "build returns empty string when text and usage footer are absent" do
    assert ResponseEnvelope.build(:telegram, nil, nil, "off") == ""
  end
end
