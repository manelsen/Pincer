defmodule Pincer.Channels.DiscordTest do
  use ExUnit.Case, async: true
  import Mox

  alias Pincer.Channels.Discord
  alias Pincer.Channels.Discord.APIMock

  setup do
    Application.put_env(:pincer, :discord_api, Pincer.Channels.Discord.APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :discord_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  describe "markdown_to_discord/1" do
    test "strips reasoning blocks" do
      input = "<thought>Internal monologue</thought>Hello world!"
      assert Discord.markdown_to_discord(input) == "Hello world!"
    end

    test "strips think> prefix" do
      input = "think> I should say hello.\n\nHello!"
      assert Discord.markdown_to_discord(input) == "Hello!"
    end

    test "preserves standard markdown" do
      input = "**Bold**, _Italic_, `Code`"
      assert Discord.markdown_to_discord(input) == "**Bold**, _Italic_, `Code`"
    end
  end

  describe "send_message/3" do
    test "divide mensagens longas em vários chunks" do
      channel_id = "123456"
      long_text = String.duplicate("a", 2500)

      APIMock
      |> expect(:create_message, fn id, chunk1, _opts ->
        assert to_string(id) == channel_id
        assert String.length(chunk1) <= 1900
        {:ok, %{id: 9991}}
      end)
      |> expect(:create_message, fn id, chunk2, _opts ->
        assert to_string(id) == channel_id
        assert String.length(chunk2) > 0
        {:ok, %{id: 9992}}
      end)

      assert Discord.send_message(channel_id, long_text) == {:ok, 9991}
    end

    test "anexa arquivos corretamente no primeiro chunk" do
      channel_id = "123456"
      text = "hello"
      files = [%{path: "/tmp/test.txt", filename: "test.txt"}]

      APIMock
      |> expect(:create_message, fn id, ^text, opts ->
        assert to_string(id) == channel_id
        assert opts[:files] == files
        {:ok, %{id: 12345}}
      end)

      assert Discord.send_message(channel_id, text, files: files) == {:ok, 12345}
    end
  end

  describe "update_message/3" do
    test "instancia edição via API do Discord" do
      channel_id = "123456"
      mid = 111
      text = "modificado"

      APIMock
      |> expect(:edit_message, fn id, ^mid, opts ->
        assert id == 123_456
        assert opts[:content] == text
        {:ok, %{}}
      end)

      assert Discord.update_message(channel_id, mid, text) == :ok
    end
  end

  describe "register_commands/0" do
    test "envia comandos globais para o Discord" do
      APIMock
      |> expect(:bulk_overwrite_global_commands, fn commands ->
        assert is_list(commands)
        assert length(commands) == 6
        assert Enum.any?(commands, &(&1.name == "ping"))
        assert Enum.any?(commands, &(&1.name == "menu"))
        assert Enum.any?(commands, &(&1.name == "kanban"))
        assert Enum.any?(commands, &(&1.name == "project"))
        {:ok, %{}}
      end)

      assert Discord.register_commands() == :ok
    end
  end

  describe "dm access policy" do
    test "blocked DM sends friendly message" do
      Application.put_env(:pincer, :discord_channel_config, %{
        "dm_policy" => %{"mode" => "disabled"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :discord_channel_config)
      end)

      APIMock
      |> expect(:create_message, fn 456, content, _opts ->
        assert content =~ "desativadas"
        {:ok, %{id: 91}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "oi",
        channel_id: 456,
        guild_id: nil,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end
  end

  describe "pairing command workflow" do
    test "DM /pair <code> bypasses gate and returns pending guidance when no request exists" do
      Application.put_env(:pincer, :discord_channel_config, %{
        "dm_policy" => %{"mode" => "pairing"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :discord_channel_config)
      end)

      sender_id = "u-pair-#{System.unique_integer([:positive])}"

      APIMock
      |> expect(:create_message, fn 456, content, _opts ->
        assert content =~ "Nenhum pairing pendente"
        {:ok, %{id: 811}}
      end)

      message = %{
        author: %{bot: false, username: "tester", id: sender_id},
        content: "/pair 000000",
        channel_id: 456,
        guild_id: nil,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end
  end

  describe "menu ergonomics parity" do
    test "plain Menu text triggers help menu response" do
      APIMock
      |> expect(:create_message, fn 888, content, _opts ->
        assert content == Pincer.Core.UX.help_text(:discord)
        {:ok, %{id: 123}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "Menu",
        channel_id: 888,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end

    test "plain status text routes to /status for keyboard-first navigation" do
      APIMock
      |> expect(:create_message, fn 889, content, _opts ->
        assert content =~ "Session Status"
        {:ok, %{id: 124}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "status",
        channel_id: 889,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end

    test "plain kanban text routes to /kanban for board visualization" do
      APIMock
      |> expect(:create_message, fn 890, content, _opts ->
        assert content =~ "Kanban indisponivel para esta sessao"
        assert content =~ "/project"
        {:ok, %{id: 125}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "kanban",
        channel_id: 890,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end

    test "kanban uses session project board when plan is ready" do
      session_id = "discord_893"
      Pincer.Core.ProjectOrchestrator.reset(session_id)

      Pincer.Core.ProjectOrchestrator.start(session_id)

      {:handled, _} =
        Pincer.Core.ProjectOrchestrator.continue(session_id, "Comprar parafusadeira")

      {:handled, _} = Pincer.Core.ProjectOrchestrator.continue(session_id, "nao-software")
      {:handled, _} = Pincer.Core.ProjectOrchestrator.continue(session_id, "Belo Horizonte")
      {:handled, _} = Pincer.Core.ProjectOrchestrator.continue(session_id, "Top 3 com preco")

      APIMock
      |> expect(:create_message, fn 893, content, _opts ->
        assert content =~ "Kanban Board"
        assert content =~ "Project: Comprar parafusadeira"
        assert content =~ "Flow Research/Validation"
        {:ok, %{id: 129}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "kanban",
        channel_id: 893,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
      Pincer.Core.ProjectOrchestrator.reset(session_id)
    end

    test "plain project text routes to project manager wizard" do
      APIMock
      |> expect(:create_message, fn 891, content, _opts ->
        assert content =~ "Project Manager"
        assert content =~ "Qual e o objetivo principal?"
        {:ok, %{id: 126}}
      end)

      message = %{
        author: %{bot: false, username: "tester"},
        content: "project",
        channel_id: 891,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end

    test "project wizard follow-up text is captured before default session flow" do
      APIMock
      |> expect(:create_message, fn 892, content, _opts ->
        assert content =~ "Project Manager"
        {:ok, %{id: 127}}
      end)
      |> expect(:create_message, fn 892, content, _opts ->
        assert content =~ "tipo do projeto"
        {:ok, %{id: 128}}
      end)

      project_start = %{
        author: %{bot: false, username: "tester"},
        content: "project",
        channel_id: 892,
        guild_id: 777,
        attachments: []
      }

      follow_up = %{
        author: %{bot: false, username: "tester"},
        content: "Quero pesquisar parafusadeiras em Belo Horizonte",
        channel_id: 892,
        guild_id: 777,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, project_start, nil})
      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, follow_up, nil})
    end

    test "models interaction includes a Menu fallback button" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{default_model: "glm-4.7"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :llm_providers)
      end)

      APIMock
      |> expect(:create_interaction_response, fn 111, "token-1", response ->
        assert response.type == 4
        assert response.data.content =~ "Select AI Provider"

        custom_ids =
          response.data.components
          |> Enum.flat_map(&Map.get(&1, :components, []))
          |> Enum.map(&Map.get(&1, :custom_id))

        assert "show_menu" in custom_ids
        :ok
      end)

      interaction = %{
        id: 111,
        token: "token-1",
        channel_id: 456,
        type: 2,
        data: %{name: "models"}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end

    test "models interaction filters provider custom_id above discord limit" do
      long_provider = "provider_" <> String.duplicate("x", 120)

      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{default_model: "glm-4.7"},
        long_provider => %{default_model: "model-x"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :llm_providers)
      end)

      APIMock
      |> expect(:create_interaction_response, fn 119, "token-119", response ->
        assert response.type == 4

        custom_ids =
          response.data.components
          |> Enum.flat_map(&Map.get(&1, :components, []))
          |> Enum.map(&Map.get(&1, :custom_id))
          |> Enum.reject(&is_nil/1)

        assert "select_provider:z_ai" in custom_ids
        assert "show_menu" in custom_ids
        assert Enum.all?(custom_ids, &(byte_size(&1) <= 100))
        refute Enum.any?(custom_ids, &String.contains?(&1, long_provider))
        :ok
      end)

      interaction = %{
        id: 119,
        token: "token-119",
        channel_id: 456,
        type: 2,
        data: %{name: "models"}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end
  end

  describe "interaction fallback hardening" do
    test "unknown custom_id responds with guidance instead of crashing" do
      APIMock
      |> expect(:create_interaction_response, fn 222, "token-2", response ->
        assert response.type == 7
        assert response.data.content =~ "Use /menu"

        custom_ids =
          response.data.components
          |> Enum.flat_map(&Map.get(&1, :components, []))
          |> Enum.map(&Map.get(&1, :custom_id))

        assert "show_menu" in custom_ids
        :ok
      end)

      interaction = %{
        id: 222,
        token: "token-2",
        channel_id: 456,
        type: 3,
        data: %{custom_id: "unknown_action"}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end

    test "invalid select_model payload does not crash and returns guidance" do
      APIMock
      |> expect(:create_interaction_response, fn 333, "token-3", response ->
        assert response.type == 7
        assert response.data.content =~ "Use /menu"
        :ok
      end)

      interaction = %{
        id: 333,
        token: "token-3",
        channel_id: 456,
        type: 3,
        data: %{custom_id: "select_model:invalid_payload"}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end

    test "missing custom_id does not crash and returns guidance" do
      APIMock
      |> expect(:create_interaction_response, fn 334, "token-4", response ->
        assert response.type == 7
        assert response.data.content =~ "Use /menu"
        :ok
      end)

      interaction = %{
        id: 334,
        token: "token-4",
        channel_id: 456,
        type: 3,
        data: %{}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end

    test "malformed interaction flood without id/token does not call Discord API" do
      APIMock
      |> expect(:create_interaction_response, fn 335, "token-5", response ->
        assert response.type == 7
        assert response.data.content =~ "Use /menu"
        :ok
      end)

      malformed =
        for n <- 1..50 do
          %{
            id: nil,
            token: nil,
            channel_id: 456,
            type: 3,
            data: %{custom_id: "unknown_action_#{n}"}
          }
        end

      valid = %{
        id: 335,
        token: "token-5",
        channel_id: 456,
        type: 3,
        data: %{custom_id: "unknown_action"}
      }

      Enum.each(malformed ++ [valid], fn interaction ->
        Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
      end)
    end
  end

  describe "dm session scope policy" do
    test "DM /status uses main session scope when configured" do
      Application.put_env(:pincer, :discord_channel_config, %{
        "dm_session_scope" => "main"
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :discord_channel_config)
      end)

      APIMock
      |> expect(:create_message, fn 456, content, _opts ->
        assert content =~ "discord_main"
        {:ok, %{id: 444}}
      end)

      message = %{
        author: %{bot: false, username: "tester", id: "u-1"},
        content: "/status",
        channel_id: 456,
        guild_id: nil,
        attachments: []
      }

      Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
    end

    test "DM select_model interaction uses main session scope when configured" do
      Application.put_env(:pincer, :discord_channel_config, %{
        "dm_session_scope" => "main"
      })

      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{default_model: "glm-4.7"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :discord_channel_config)
        Application.delete_env(:pincer, :llm_providers)
      end)

      APIMock
      |> expect(:create_interaction_response, fn 934, "token-934", response ->
        assert response.type == 7
        assert response.data.content =~ "Session: `discord_main`"
        :ok
      end)

      interaction = %{
        id: 934,
        token: "token-934",
        channel_id: 456,
        guild_id: nil,
        type: 3,
        data: %{custom_id: "select_model:z_ai:glm-4.7"}
      }

      Pincer.Channels.Discord.Consumer.handle_event({:INTERACTION_CREATE, interaction, nil})
    end
  end
end
