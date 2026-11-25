defmodule Pincer.Ports.LLMTest do
  use ExUnit.Case, async: true

  test "the legacy port keeps the shared port's functions and callbacks" do
    assert Pincer.Ports.LLM.__info__(:functions) ==
             PincerPorts.LLM.__info__(:functions)

    assert Pincer.Ports.LLM.behaviour_info(:callbacks) ==
             PincerPorts.LLM.behaviour_info(:callbacks)
  end
end
