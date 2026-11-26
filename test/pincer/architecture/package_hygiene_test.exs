defmodule Pincer.Architecture.PackageHygieneTest do
  @moduledoc """
  Enforces canonical manifest parity, standardized subpackage `mix.exs` metadata,
  and shared `OpenAICompat` provider defaults across all 25 monorepo packages.
  """

  use ExUnit.Case, async: true

  alias Pincer.Plugin.Manifest

  @expected_package_count 25
  @expected_source_url "https://github.com/manelsen/Pincer"

  @openai_compat_provider_files [
    "packages/pincer_deepseek/lib/pincer/llm/providers/deepseek.ex",
    "packages/pincer_groq/lib/pincer/llm/providers/groq.ex",
    "packages/pincer_minimax/lib/pincer/llm/providers/minimax.ex",
    "packages/pincer_mistral/lib/pincer/llm/providers/mistral.ex",
    "packages/pincer_moonshot/lib/pincer/llm/providers/moonshot.ex",
    "packages/pincer_openai/lib/pincer/llm/providers/openai.ex",
    "packages/pincer_opencode_zen/lib/pincer/llm/providers/opencode_zen.ex",
    "packages/pincer_openrouter/lib/pincer/llm/providers/openrouter.ex",
    "packages/pincer_qwen/lib/pincer/llm/providers/qwen.ex",
    "packages/pincer_zhipu/lib/pincer/llm/providers/zhipu.ex"
  ]

  @openai_compat_provider_modules [
    Pincer.LLM.Providers.DeepSeek,
    Pincer.LLM.Providers.Groq,
    Pincer.LLM.Providers.MiniMax,
    Pincer.LLM.Providers.Mistral,
    Pincer.LLM.Providers.Moonshot,
    Pincer.LLM.Providers.OpenAI,
    Pincer.LLM.Providers.OpencodeZen,
    Pincer.LLM.Providers.OpenRouter,
    Pincer.LLM.Providers.Qwen,
    Pincer.LLM.Providers.Zhipu
  ]

  describe "plugin manifest parity" do
    test "every priv/plugins/<name>/pincer_plugin.yaml matches packages/pincer_<name>/priv/pincer_plugin.yaml" do
      root_manifests = Path.wildcard("priv/plugins/*/pincer_plugin.yaml") |> Enum.sort()
      pkg_manifests = Path.wildcard("packages/pincer_*/priv/pincer_plugin.yaml") |> Enum.sort()

      assert root_manifests != []
      assert length(root_manifests) == length(pkg_manifests)

      for root_path <- root_manifests do
        name = root_path |> Path.dirname() |> Path.basename()
        pkg_path = Path.join(["packages", "pincer_#{name}", "priv", "pincer_plugin.yaml"])

        assert File.exists?(pkg_path), "Missing package manifest #{pkg_path} for #{root_path}"

        assert File.read!(root_path) == File.read!(pkg_path),
               "Manifest drift detected between #{root_path} and #{pkg_path}"

        assert {:ok, %Manifest{id: ^name, version: "0.1.0"}} = Manifest.from_file(root_path)
      end
    end
  end

  describe "subpackage mix.exs metadata" do
    test "all 25 packages define canonical mix.exs structure and Hex metadata" do
      projects = Path.wildcard("packages/*/mix.exs") |> Enum.sort()
      assert length(projects) == @expected_package_count

      for file <- projects do
        pkg_dir = Path.dirname(file)
        pkg_name = Path.basename(pkg_dir)
        ast = parse!(file)

        assert has_module_attr?(ast, :version),
               "#{file} must define @version module attribute"

        assert has_module_attr?(ast, :source_url, @expected_source_url),
               "#{file} must define @source_url #{@expected_source_url}"

        for key <- [
              :app,
              :version,
              :elixir,
              :elixirc_options,
              :start_permanent,
              :deps,
              :description,
              :package,
              :name,
              :source_url
            ] do
          assert has_keyword_entry?(ast, key),
                 "#{file} project/0 must define :#{key}"
        end

        assert has_keyword_value?(ast, :elixir, "~> 1.14"),
               "#{file} must constrain elixir to \"~> 1.14\""

        assert has_keyword_value?(ast, :start_permanent, false),
               "#{file} must set start_permanent: false"

        for helper <- [:deps, :description, :package] do
          assert defines_private_fun?(ast, helper, 0),
                 "#{file} must define private helper #{helper}/0"
        end

        assert has_keyword_value?(ast, :name, pkg_name),
               "#{file} package/0 must set name: #{inspect(pkg_name)}"

        assert has_keyword_value?(ast, :licenses, ["MIT"]),
               "#{file} package/0 must set licenses: [\"MIT\"]"

        assert has_keyword_value?(ast, :maintainers, ["Micelio"]),
               "#{file} package/0 must set maintainers: [\"Micelio\"]"

        assert has_keyword_entry?(ast, :links),
               "#{file} package/0 must set :links"

        assert has_keyword_entry?(ast, :files),
               "#{file} package/0 must set :files"

        if File.exists?(Path.join(pkg_dir, "priv/pincer_plugin.yaml")) do
          assert package_files_includes?(ast, "priv/pincer_plugin.yaml"),
                 "#{file} package/0 :files must include \"priv/pincer_plugin.yaml\""
        end
      end
    end
  end

  describe "OpenAICompat provider hygiene" do
    test "OpenAICompat-backed provider modules use Pincer.LLM.Providers.OpenAICompat defaults" do
      for file <- @openai_compat_provider_files do
        ast = parse!(file)

        assert uses_openai_compat?(ast),
               "#{file} must `use Pincer.LLM.Providers.OpenAICompat`"

        refute defines_not_implemented_stub?(ast, :transcribe_audio, 3),
               "#{file} must inherit default transcribe_audio/3 from OpenAICompat"

        refute defines_not_implemented_stub?(ast, :generate_embedding, 3),
               "#{file} must inherit default generate_embedding/3 from OpenAICompat"
      end
    end

    test "OpenAICompat-backed provider modules export all behaviour callbacks with expected defaults" do
      for mod <- @openai_compat_provider_modules do
        behaviours = mod.module_info(:attributes)[:behaviour] || []
        assert PincerPorts.LLM.Provider in behaviours

        for {fun, arity} <- [
              chat_completion: 4,
              stream_completion: 4,
              list_models: 1,
              transcribe_audio: 3,
              generate_embedding: 3
            ] do
          assert function_exported?(mod, fun, arity),
                 "#{inspect(mod)} must export #{fun}/#{arity}"
        end

        assert mod.transcribe_audio("/tmp/none.mp3", "m", %{}) == {:error, :not_implemented}
      end

      for mod <-
            @openai_compat_provider_modules --
              [
                Pincer.LLM.Providers.Mistral,
                Pincer.LLM.Providers.OpenAI,
                Pincer.LLM.Providers.OpenRouter
              ] do
        assert mod.generate_embedding("hello", "m", %{}) == {:error, :not_implemented}
      end
    end
  end

  defp parse!(file), do: file |> File.read!() |> Code.string_to_quoted!(file: file)

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end

  defp has_module_attr?(ast, attr) do
    contains?(ast, fn
      {:@, _, [{^attr, _, [_val]}]} -> true
      _ -> false
    end)
  end

  defp has_module_attr?(ast, attr, value) do
    contains?(ast, fn
      {:@, _, [{^attr, _, [^value]}]} -> true
      _ -> false
    end)
  end

  defp has_keyword_entry?(ast, key) do
    contains?(ast, fn
      {^key, _val} -> true
      _ -> false
    end)
  end

  defp has_keyword_value?(ast, key, value) do
    contains?(ast, fn
      {^key, ^value} -> true
      _ -> false
    end)
  end

  defp defines_private_fun?(ast, name, arity) do
    contains?(ast, fn
      {:defp, _, [{^name, _, args}, _body]} -> length(args || []) == arity
      {:defp, _, [{:when, _, [{^name, _, args} | _]}, _body]} -> length(args || []) == arity
      _ -> false
    end)
  end

  defp package_files_includes?(ast, target) do
    contains?(ast, fn
      {:files, list} when is_list(list) -> target in list
      _ -> false
    end)
  end

  defp uses_openai_compat?(ast) do
    contains?(ast, fn
      {:use, _, [{:__aliases__, _, [:Pincer, :LLM, :Providers, :OpenAICompat]} | _]} -> true
      _ -> false
    end)
  end

  defp defines_not_implemented_stub?(ast, name, arity) do
    contains?(ast, fn
      {:def, _, [{^name, _, args}, [do: {:error, :not_implemented}]]} ->
        length(args || []) == arity

      _ ->
        false
    end)
  end
end
