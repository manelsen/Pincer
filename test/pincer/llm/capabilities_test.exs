defmodule Pincer.LLM.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AuthProfiles
  alias Pincer.LLM.Capabilities

  defmodule CapabilityAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, _config, _tools), do: {:ok, %{}, nil}

    @impl true
    def stream_completion(_messages, _model, _config, _tools), do: {:ok, []}

    @impl true
    def transcribe_audio(file_path, model, config) do
      send(self(), {:transcribe_called, file_path, model, config[:api_key]})

      case config[:transcribe_result] do
        nil -> {:ok, "transcribed:#{file_path}"}
        result -> result
      end
    end

    @impl true
    def generate_embedding(text, model, config) do
      send(self(), {:embedding_called, text, model, config[:api_key]})

      case config[:embedding_behavior] do
        {:retryable_then_ok, retryable_error} ->
          if model == "baai/bge-m3" do
            retryable_error
          else
            {:ok, [0.5, 0.6]}
          end

        {:error, _} = err ->
          err

        nil ->
          {:ok, [0.1, 0.2]}
      end
    end
  end

  setup do
    orig_providers = Application.get_env(:pincer, :llm_providers)
    old_key = System.get_env("CAPABILITIES_TEST_KEY")

    AuthProfiles.reset()
    System.put_env("CAPABILITIES_TEST_KEY", "cap-secret-1")

    on_exit(fn ->
      AuthProfiles.reset()

      if orig_providers do
        Application.put_env(:pincer, :llm_providers, orig_providers)
      else
        Application.delete_env(:pincer, :llm_providers)
      end

      if old_key do
        System.put_env("CAPABILITIES_TEST_KEY", old_key)
      else
        System.delete_env("CAPABILITIES_TEST_KEY")
      end
    end)

    :ok
  end

  describe "transcribe_audio/2" do
    test "returns :unknown_provider when configured provider is missing" do
      Application.put_env(:pincer, :llm_providers, %{})
      assert {:error, :unknown_provider} = Capabilities.transcribe_audio("/tmp/audio.ogg")
    end

    test "returns auth error when credentials are missing" do
      System.delete_env("CAPABILITIES_TEST_KEY")

      Application.put_env(:pincer, :llm_providers, %{
        "groq_whisper" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "whisper-large-v3"
        }
      })

      assert {:error, :missing_credentials} = Capabilities.transcribe_audio("/tmp/audio.ogg")
    end

    test "resolves auth profile, delegates to adapter, and normalizes wrapped errors" do
      Application.put_env(:pincer, :llm_providers, %{
        "groq_whisper" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "whisper-large-v3"
        },
        "err_whisper" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "whisper-large-v3",
          transcribe_result: {:error, %Req.TransportError{reason: :timeout}}
        }
      })

      assert {:ok, "transcribed:/tmp/a.ogg"} = Capabilities.transcribe_audio("/tmp/a.ogg")
      assert_received {:transcribe_called, "/tmp/a.ogg", "whisper-large-v3", "cap-secret-1"}

      assert {:error, {:transport_error, :timeout}} =
               Capabilities.transcribe_audio("/tmp/b.ogg", provider: "err_whisper")
    end
  end

  describe "generate_embedding/2" do
    test "uses baai/bge-m3 default for openrouter and retries with baai/bge-large-en-v1.5 on 404/200 router miss" do
      retryable_error =
        {:error,
         {:http_error, 200,
          %{"error" => %{"code" => 404, "message" => "No successful provider responses."}}}}

      Application.put_env(:pincer, :llm_providers, %{
        "openrouter" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "chat-model",
          embedding_behavior: {:retryable_then_ok, retryable_error}
        }
      })

      assert {:ok, [0.5, 0.6]} = Capabilities.generate_embedding("hello world")
      assert_received {:embedding_called, "hello world", "baai/bge-m3", "cap-secret-1"}
      assert_received {:embedding_called, "hello world", "baai/bge-large-en-v1.5", "cap-secret-1"}
    end

    test "uses configured embedding_fallback_model and skips retry when explicit :model is passed" do
      retryable_error =
        {:error,
         {:http_error, 404, %{"error" => %{"message" => "No successful provider responses."}}}}

      Application.put_env(:pincer, :llm_providers, %{
        "openrouter" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "chat-model",
          embedding_fallback_model: "custom/fallback-embed",
          embedding_behavior: {:retryable_then_ok, retryable_error}
        }
      })

      assert {:ok, [0.5, 0.6]} = Capabilities.generate_embedding("probe")
      assert_received {:embedding_called, "probe", "baai/bge-m3", "cap-secret-1"}
      assert_received {:embedding_called, "probe", "custom/fallback-embed", "cap-secret-1"}

      assert {:error, {:http_error, 404, _}} =
               Capabilities.generate_embedding("probe", model: "baai/bge-m3")

      assert_received {:embedding_called, "probe", "baai/bge-m3", "cap-secret-1"}
      refute_received {:embedding_called, "probe", "custom/fallback-embed", _}
    end

    test "normalizes nested errors from embedding adapter" do
      Application.put_env(:pincer, :llm_providers, %{
        "custom_embed" => %{
          adapter: CapabilityAdapter,
          env_key: "CAPABILITIES_TEST_KEY",
          default_model: "text-embedding-3-small",
          embedding_behavior: {:error, {:error, %Req.TransportError{reason: :closed}}}
        }
      })

      assert {:error, {:transport_error, :closed}} =
               Capabilities.generate_embedding("probe", provider: "custom_embed")
    end
  end
end
