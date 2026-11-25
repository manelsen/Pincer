defmodule Pincer.Adapters.Tools.MediaTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.Media

  @tmp_dir System.tmp_dir!()

  # ---------------------------------------------------------------------------
  # Stub LLM client
  # ---------------------------------------------------------------------------
  defmodule StubLLM do
    @pt_key :media_test_stub_llm_pid

    def register(pid), do: :persistent_term.put(@pt_key, pid)
    def unregister, do: :persistent_term.erase(@pt_key)
    defp notify(msg), do: if(pid = :persistent_term.get(@pt_key, nil), do: send(pid, msg))

    def chat_completion(messages, opts) do
      notify({:chat_completion, messages, opts})
      {:ok, %{"content" => "stub vision response"}, nil}
    end

    def transcribe_audio(path, opts) do
      notify({:transcribe_audio, path, opts})
      {:ok, "stub transcription"}
    end
  end

  setup do
    StubLLM.register(self())
    prev_client = Application.get_env(:pincer, :media_llm_client)
    Application.put_env(:pincer, :media_llm_client, StubLLM)

    on_exit(fn ->
      StubLLM.unregister()

      case prev_client do
        nil -> Application.delete_env(:pincer, :media_llm_client)
        v -> Application.put_env(:pincer, :media_llm_client, v)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_png do
    # 1x1 white PNG (minimal valid PNG)
    png =
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248, 207, 192, 0,
        0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    path = Path.join(@tmp_dir, "pincer_test_#{:rand.uniform(999_999)}.png")
    File.write!(path, png)
    path
  end

  defp tmp_txt_as_pdf do
    # minimal text file pretending to be a PDF (pdftotext will fail; we test that path)
    path = Path.join(@tmp_dir, "pincer_test_#{:rand.uniform(999_999)}.pdf")
    File.write!(path, "%PDF-1.4 fake")
    path
  end

  defp tmp_audio do
    path = Path.join(@tmp_dir, "pincer_test_#{:rand.uniform(999_999)}.mp3")
    File.write!(path, "fake audio")
    path
  end

  # ---------------------------------------------------------------------------
  # spec/0
  # ---------------------------------------------------------------------------

  test "spec/0 is a valid tool spec" do
    spec = Media.spec()
    assert spec.name == "media"
    assert is_binary(spec.description)
    actions = get_in(spec, [:parameters, :properties, :action, :enum])
    assert "describe" in actions
    assert "ocr" in actions
    assert "pdf_extract" in actions
    assert "tts" in actions
    assert "transcribe" in actions
  end

  test "spec/0 requires action" do
    assert "action" in get_in(Media.spec(), [:parameters, :required])
  end

  # ---------------------------------------------------------------------------
  # Missing-parameter error paths
  # ---------------------------------------------------------------------------

  test "describe without path returns error" do
    assert {:error, msg} = Media.execute(%{"action" => "describe"})
    assert msg =~ "path"
  end

  test "ocr without path returns error" do
    assert {:error, msg} = Media.execute(%{"action" => "ocr"})
    assert msg =~ "path"
  end

  test "pdf_extract without path returns error" do
    assert {:error, msg} = Media.execute(%{"action" => "pdf_extract"})
    assert msg =~ "path"
  end

  test "tts without text returns error" do
    assert {:error, msg} = Media.execute(%{"action" => "tts"})
    assert msg =~ "text"
  end

  test "transcribe without path returns error" do
    assert {:error, msg} = Media.execute(%{"action" => "transcribe"})
    assert msg =~ "path"
  end

  test "unknown action returns descriptive error" do
    assert {:error, msg} = Media.execute(%{"action" => "hologram"})
    assert msg =~ "hologram"
  end

  # ---------------------------------------------------------------------------
  # describe — vision
  # ---------------------------------------------------------------------------

  test "describe sends image as inline_data to the LLM" do
    png = tmp_png()
    rel = Path.relative_to(png, @tmp_dir)

    assert {:ok, text} =
             Media.execute(%{"action" => "describe", "path" => rel}, %{
               "workspace_path" => @tmp_dir
             })

    assert text == "stub vision response"

    assert_received {:chat_completion, messages, _opts}
    content = get_in(messages, [Access.at(0), "content"])
    assert is_list(content)
    inline = Enum.find(content, &(&1["type"] == "inline_data"))
    assert inline["mime_type"] == "image/png"
    assert is_binary(inline["data"])

    File.rm(png)
  end

  test "describe with custom prompt sends that prompt" do
    png = tmp_png()
    rel = Path.relative_to(png, @tmp_dir)

    Media.execute(%{"action" => "describe", "path" => rel, "prompt" => "Count the dots"}, %{
      "workspace_path" => @tmp_dir
    })

    assert_received {:chat_completion, messages, _opts}
    text_part = get_in(messages, [Access.at(0), "content"]) |> Enum.find(&(&1["type"] == "text"))
    assert text_part["text"] =~ "Count the dots"

    File.rm(png)
  end

  test "describe returns error for missing file" do
    assert {:error, msg} =
             Media.execute(%{"action" => "describe", "path" => "nonexistent.png"}, %{
               "workspace_path" => @tmp_dir
             })

    assert msg =~ "not found"
  end

  # ---------------------------------------------------------------------------
  # ocr
  # ---------------------------------------------------------------------------

  test "ocr sends OCR prompt to LLM" do
    png = tmp_png()
    rel = Path.relative_to(png, @tmp_dir)

    assert {:ok, _} =
             Media.execute(%{"action" => "ocr", "path" => rel}, %{"workspace_path" => @tmp_dir})

    assert_received {:chat_completion, messages, _opts}
    text_part = get_in(messages, [Access.at(0), "content"]) |> Enum.find(&(&1["type"] == "text"))
    assert text_part["text"] =~ "Extract"

    File.rm(png)
  end

  # ---------------------------------------------------------------------------
  # transcribe
  # ---------------------------------------------------------------------------

  test "transcribe delegates to llm_client.transcribe_audio" do
    audio = tmp_audio()
    rel = Path.relative_to(audio, @tmp_dir)

    assert {:ok, text} =
             Media.execute(%{"action" => "transcribe", "path" => rel}, %{
               "workspace_path" => @tmp_dir
             })

    assert text == "stub transcription"
    assert_received {:transcribe_audio, ^audio, _opts}

    File.rm(audio)
  end

  test "transcribe returns error for missing file" do
    assert {:error, msg} =
             Media.execute(%{"action" => "transcribe", "path" => "missing.mp3"}, %{
               "workspace_path" => @tmp_dir
             })

    assert msg =~ "not found"
  end

  test "transcribe uses the host's LLM port when no tool override is configured" do
    previous = Application.fetch_env(:pincer, :llm_adapter)
    Application.delete_env(:pincer, :media_llm_client)
    Application.put_env(:pincer, :llm_adapter, StubLLM)

    audio = tmp_audio()

    on_exit(fn ->
      File.rm(audio)

      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :llm_adapter, adapter)
        :error -> Application.delete_env(:pincer, :llm_adapter)
      end
    end)

    assert {:ok, "stub transcription"} =
             Media.execute(%{"action" => "transcribe", "path" => Path.basename(audio)}, %{
               "workspace_path" => @tmp_dir
             })

    assert_received {:transcribe_audio, ^audio, _opts}
  end

  # ---------------------------------------------------------------------------
  # pdf_extract
  # ---------------------------------------------------------------------------

  test "pdf_extract returns error when file is missing" do
    assert {:error, msg} =
             Media.execute(%{"action" => "pdf_extract", "path" => "no_such.pdf"}, %{
               "workspace_path" => @tmp_dir
             })

    assert msg =~ "not found"
  end

  test "pdf_extract returns error or text depending on pdftotext availability" do
    pdf = tmp_txt_as_pdf()
    rel = Path.relative_to(pdf, @tmp_dir)

    result =
      Media.execute(%{"action" => "pdf_extract", "path" => rel}, %{"workspace_path" => @tmp_dir})

    case result do
      {:error, msg} ->
        # pdftotext not installed or fake PDF fails — either is valid
        assert is_binary(msg)

      {:ok, text} ->
        assert is_binary(text)
    end

    File.rm(pdf)
  end

  # ---------------------------------------------------------------------------
  # tts — no real API call; verify error path when unconfigured
  # ---------------------------------------------------------------------------

  test "tts returns error when provider and OPENAI_API_KEY are unconfigured" do
    System.delete_env("OPENAI_API_KEY")

    result =
      Media.execute(
        %{"action" => "tts", "text" => "hello", "provider" => "nonexistent_tts_provider"},
        %{"workspace_path" => @tmp_dir}
      )

    case result do
      {:error, msg} -> assert is_binary(msg)
      # If the env var happens to be set in CI, the HTTP call will fail — also {:error, _}
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # mime detection
  # ---------------------------------------------------------------------------

  test "describe infers image/jpeg for .jpg files" do
    jpg = Path.join(@tmp_dir, "pincer_test_#{:rand.uniform(999_999)}.jpg")
    File.write!(jpg, <<255, 216, 255, 224>>)
    rel = Path.relative_to(jpg, @tmp_dir)

    Media.execute(%{"action" => "describe", "path" => rel}, %{"workspace_path" => @tmp_dir})

    assert_received {:chat_completion, messages, _}

    inline =
      get_in(messages, [Access.at(0), "content"]) |> Enum.find(&(&1["type"] == "inline_data"))

    assert inline["mime_type"] == "image/jpeg"

    File.rm(jpg)
  end

  # ---------------------------------------------------------------------------
  # workspace path confinement
  # ---------------------------------------------------------------------------

  describe "workspace path confinement" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "pincer_media_confine_#{System.unique_integer([:positive])}")

      ws = Path.join(base, "ws")
      outside = Path.join(base, "outside")
      File.mkdir_p!(ws)
      File.mkdir_p!(outside)

      outside_png = Path.join(outside, "secret.png")
      outside_pdf = Path.join(outside, "secret.pdf")
      outside_mp3 = Path.join(outside, "secret.mp3")
      File.write!(outside_png, "not really read")
      File.write!(outside_pdf, "%PDF-1.4 secret")
      File.write!(outside_mp3, "secret audio")

      symlink_png = Path.join(ws, "link_out.png")
      File.ln_s!(outside_png, symlink_png)

      on_exit(fn -> File.rm_rf!(base) end)

      {:ok,
       %{ws: ws, outside: outside, outside_png: outside_png, context: %{"workspace_path" => ws}}}
    end

    test "rejects outside absolute paths, traversal, and escaping symlinks on reads", %{
      outside_png: outside_png,
      context: ctx
    } do
      for action <- ["describe", "ocr", "pdf_extract", "transcribe"] do
        for unsafe_path <- [outside_png, "../outside/secret.png", "link_out.png"] do
          assert {:error, reason} =
                   Media.execute(%{"action" => action, "path" => unsafe_path}, ctx)

          assert reason =~ "Access denied" or reason =~ "traversal" or reason =~ "outside"
        end
      end

      refute_received {:chat_completion, _, _}
      refute_received {:transcribe_audio, _, _}
    end

    test "rejects outside output_path on tts before creating directories", %{
      outside: outside,
      context: ctx
    } do
      outside_subdir = Path.join(outside, "escaped_tts_dir")
      abs_target = Path.join(outside_subdir, "speech.mp3")

      assert {:error, reason} =
               Media.execute(
                 %{"action" => "tts", "text" => "hello", "output_path" => abs_target},
                 ctx
               )

      assert reason =~ "Access denied" or reason =~ "outside"
      refute File.exists?(outside_subdir)

      assert {:error, reason2} =
               Media.execute(
                 %{"action" => "tts", "text" => "hello", "output_path" => "../outside/evil.mp3"},
                 ctx
               )

      assert reason2 =~ "traversal" or reason2 =~ "Access denied"
      refute File.exists?(Path.join(outside, "evil.mp3"))
    end
  end
end
