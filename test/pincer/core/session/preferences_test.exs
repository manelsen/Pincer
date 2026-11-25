defmodule Pincer.Core.Session.PreferencesTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.Preferences
  alias PincerPorts.Structs.Usage

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_prefs_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{workspace: tmp}
  end

  test "returns canonical defaults when preferences file does not exist", %{workspace: workspace} do
    prefs = Preferences.load(workspace)

    assert prefs.model_override == nil
    assert prefs.thinking_level == nil
    assert prefs.reasoning_visible == false
    assert prefs.usage_display == "off"

    assert prefs.token_usage_total == %Usage{
             prompt_tokens: 0,
             completion_tokens: 0,
             total_tokens: 0
           }
  end

  test "saves and reloads preferences with atom-keyed model_override and Usage struct", %{
    workspace: workspace
  } do
    prefs = %{
      model_override: %{provider: "z_ai_coding", model: "glm-4.7"},
      thinking_level: "high",
      reasoning_visible: true,
      usage_display: "tokens",
      token_usage_total: %Usage{prompt_tokens: 120, completion_tokens: 45, total_tokens: 165}
    }

    assert :ok = Preferences.save(workspace, prefs)

    loaded = Preferences.load(workspace)
    assert loaded.model_override == %{provider: "z_ai_coding", model: "glm-4.7"}
    assert loaded.thinking_level == "high"
    assert loaded.reasoning_visible == true
    assert loaded.usage_display == "tokens"

    assert loaded.token_usage_total == %Usage{
             prompt_tokens: 120,
             completion_tokens: 45,
             total_tokens: 165
           }
  end

  test "falls back to defaults on malformed JSON", %{workspace: workspace} do
    pincer_dir = Path.join(workspace, ".pincer")
    File.mkdir_p!(pincer_dir)
    File.write!(Path.join(pincer_dir, "preferences.json"), "{invalid json")

    prefs = Preferences.load(workspace)
    assert prefs.model_override == nil
    assert prefs.token_usage_total == %Usage{}
  end

  test "drops incomplete model_override payloads safely", %{workspace: workspace} do
    pincer_dir = Path.join(workspace, ".pincer")
    File.mkdir_p!(pincer_dir)

    File.write!(
      Path.join(pincer_dir, "preferences.json"),
      Jason.encode!(%{
        "model_override" => %{"provider" => "only_provider"},
        "token_usage_total" => %{"prompt_tokens" => 5}
      })
    )

    prefs = Preferences.load(workspace)
    assert prefs.model_override == nil

    assert prefs.token_usage_total == %Usage{
             prompt_tokens: 5,
             completion_tokens: 0,
             total_tokens: 5
           }
  end
end
