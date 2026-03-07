defmodule Pincer.Test.Support.LLMProviderDefaults do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @behaviour Pincer.LLM.Provider

      @impl true
      def list_models(_config), do: {:ok, []}

      @impl true
      def transcribe_audio(_file_path, _model, _config), do: {:ok, ""}

      @impl true
      def generate_embedding(_text, _model, _config), do: {:ok, []}

      defoverridable list_models: 1, transcribe_audio: 3, generate_embedding: 3
    end
  end
end

Mox.defmock(Pincer.Channels.Discord.APIMock, for: Pincer.Channels.Discord.API)
Mox.defmock(Pincer.Channels.Telegram.APIMock, for: Pincer.Channels.Telegram.API)
Mox.defmock(Pincer.Channels.Slack.APIMock, for: Pincer.Channels.Slack.API)
Mox.defmock(Pincer.LLM.ClientMock, for: Pincer.LLM.Provider)
