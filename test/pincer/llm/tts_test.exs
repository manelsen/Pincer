defmodule Pincer.LLM.TTSTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AuthProfiles
  alias Pincer.LLM.TTS
  alias Pincer.Ports.TTS, as: TTSPort

  defmodule FakeTTSAdapter do
    @behaviour Pincer.Ports.TTS

    @impl true
    def synthesize_speech(text, opts) do
      send(self(), {:fake_tts_called, text, opts})
      {:ok, "FAKE_AUDIO:#{text}"}
    end
  end

  setup do
    orig_providers = Application.fetch_env(:pincer, :llm_providers)
    orig_tts_provider = Application.fetch_env(:pincer, :tts_provider)
    orig_tts_adapter = Application.fetch_env(:pincer, :tts_adapter)
    orig_openai_key = System.get_env("OPENAI_API_KEY")
    orig_custom_key = System.get_env("TTS_TEST_API_KEY")

    AuthProfiles.reset()
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("TTS_TEST_API_KEY")

    on_exit(fn ->
      AuthProfiles.reset()

      case orig_providers do
        {:ok, val} -> Application.put_env(:pincer, :llm_providers, val)
        :error -> Application.delete_env(:pincer, :llm_providers)
      end

      case orig_tts_provider do
        {:ok, val} -> Application.put_env(:pincer, :tts_provider, val)
        :error -> Application.delete_env(:pincer, :tts_provider)
      end

      case orig_tts_adapter do
        {:ok, val} -> Application.put_env(:pincer, :tts_adapter, val)
        :error -> Application.delete_env(:pincer, :tts_adapter)
      end

      if orig_openai_key,
        do: System.put_env("OPENAI_API_KEY", orig_openai_key),
        else: System.delete_env("OPENAI_API_KEY")

      if orig_custom_key,
        do: System.put_env("TTS_TEST_API_KEY", orig_custom_key),
        else: System.delete_env("TTS_TEST_API_KEY")
    end)

    :ok
  end

  describe "Pincer.Ports.TTS" do
    test "dispatches synthesize_speech/2 to configured :tts_adapter" do
      Application.put_env(:pincer, :tts_adapter, FakeTTSAdapter)

      assert {:ok, "FAKE_AUDIO:hello"} =
               TTSPort.synthesize_speech("hello", voice: "nova", provider: "openai")

      assert_received {:fake_tts_called, "hello", [voice: "nova", provider: "openai"]}
    end

    test "raises ArgumentError clearly when :tts_adapter is missing or nil" do
      for setting <- [:__delete__, nil] do
        case setting do
          :__delete__ -> Application.delete_env(:pincer, :tts_adapter)
          val -> Application.put_env(:pincer, :tts_adapter, val)
        end

        err =
          assert_raise ArgumentError, fn ->
            TTSPort.synthesize_speech("hello")
          end

        assert Exception.message(err) =~ "tts_adapter"
      end
    end
  end

  describe "Pincer.LLM.TTS" do
    test "implements Pincer.Ports.TTS behaviour" do
      behaviours = TTS.__info__(:attributes)[:behaviour] || []
      assert Pincer.Ports.TTS in behaviours
    end

    test "resolves provider from registry + AuthProfiles and normalizes /audio/speech endpoint" do
      System.put_env("TTS_TEST_API_KEY", "tts-secret-123")

      Application.put_env(:pincer, :llm_providers, %{
        "custom_openai" => %{
          env_key: "TTS_TEST_API_KEY",
          base_url: "https://custom.example.test/v1/chat/completions",
          tts_model: "tts-1-hd"
        }
      })

      http_post = fn url, req_opts ->
        send(self(), {:http_post, url, req_opts})
        {:ok, %{status: 200, body: <<1, 2, 3, 4>>}}
      end

      assert {:ok, <<1, 2, 3, 4>>} =
               TTS.synthesize_speech("Hello world",
                 provider: "custom_openai",
                 voice: "shimmer",
                 http_post: http_post
               )

      assert_received {:http_post, "https://custom.example.test/v1/audio/speech", req_opts}
      assert Keyword.get(req_opts, :auth) == {:bearer, "tts-secret-123"}
      assert Keyword.get(req_opts, :receive_timeout) == 60_000

      assert Keyword.get(req_opts, :json) == %{
               "model" => "tts-1-hd",
               "input" => "Hello world",
               "voice" => "shimmer"
             }
    end

    test "preserves existing /audio/speech endpoint and prefers tts_base_url" do
      System.put_env("TTS_TEST_API_KEY", "tts-secret-456")

      Application.put_env(:pincer, :llm_providers, %{
        "split_provider" => %{
          env_key: "TTS_TEST_API_KEY",
          base_url: "https://chat.example.test/v1/chat/completions",
          tts_base_url: "https://speech.example.test/v1/audio/speech"
        }
      })

      http_post = fn url, _req_opts ->
        send(self(), {:http_post_url, url})
        {:ok, %{status: 200, body: "MP3"}}
      end

      assert {:ok, "MP3"} =
               TTS.synthesize_speech("Test", provider: "split_provider", http_post: http_post)

      assert_received {:http_post_url, "https://speech.example.test/v1/audio/speech"}
    end

    test "falls back to OPENAI_API_KEY when provider is not in registry" do
      Application.put_env(:pincer, :llm_providers, %{})
      System.put_env("OPENAI_API_KEY", "openai-fallback-key")

      http_post = fn url, req_opts ->
        send(self(), {:http_post, url, req_opts})
        {:ok, %{status: 200, body: "FALLBACK_MP3"}}
      end

      assert {:ok, "FALLBACK_MP3"} =
               TTS.synthesize_speech("Fallback", provider: "openai", http_post: http_post)

      assert_received {:http_post, "https://api.openai.com/v1/audio/speech", req_opts}
      assert Keyword.get(req_opts, :auth) == {:bearer, "openai-fallback-key"}

      assert Keyword.get(req_opts, :json) == %{
               "model" => "tts-1",
               "input" => "Fallback",
               "voice" => "alloy"
             }
    end

    test "returns descriptive error when provider is unconfigured and OPENAI_API_KEY is missing" do
      Application.put_env(:pincer, :llm_providers, %{})

      assert {:error, msg} = TTS.synthesize_speech("Hello", provider: "nonexistent")
      assert msg =~ "nonexistent"
      assert msg =~ "OPENAI_API_KEY"
    end

    test "returns auth error when configured provider credentials are missing or cooling down" do
      Application.put_env(:pincer, :llm_providers, %{
        "custom_tts" => %{
          env_key: "TTS_TEST_API_KEY",
          base_url: "https://custom.example.test/v1"
        }
      })

      assert {:error, :missing_credentials} =
               TTS.synthesize_speech("Hello", provider: "custom_tts")

      System.put_env("TTS_TEST_API_KEY", "k1")
      AuthProfiles.cooldown_profile("custom_tts", "default", :http_401)

      assert {:error, :all_profiles_cooling_down} =
               TTS.synthesize_speech("Hello", provider: "custom_tts")
    end

    test "formats HTTP status errors and propagates transport errors" do
      System.put_env("OPENAI_API_KEY", "openai-key")
      Application.put_env(:pincer, :llm_providers, %{})

      bad_status_post = fn _url, _opts ->
        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
      end

      assert {:error, msg} =
               TTS.synthesize_speech("Hello", provider: "openai", http_post: bad_status_post)

      assert msg =~ "401"

      transport_err_post = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end

      assert {:error, %Req.TransportError{reason: :timeout}} =
               TTS.synthesize_speech("Hello", provider: "openai", http_post: transport_err_post)
    end
  end
end
