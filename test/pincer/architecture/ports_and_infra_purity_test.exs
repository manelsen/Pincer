defmodule Pincer.Architecture.PortsAndInfraPurityTest do
  use ExUnit.Case, async: false

  test "lib/pincer/ports/** does not reference concrete LLM, Adapters, or Storage modules in code" do
    forbidden = [
      "Pincer." <> "LLM." <> "Client",
      "Pincer." <> "Adapters.",
      "Pincer." <> "Storage.",
      ~s("Pincer", "Adapters"),
      ~s("Pincer", "Storage")
    ]

    offenders =
      "lib/pincer/ports/**/*.ex"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        code = code_without_docs(file)

        forbidden
        |> Enum.filter(&String.contains?(code, &1))
        |> Enum.map(&{file, &1})
      end)

    assert offenders == [],
           "Expected no concrete adapter references in lib/pincer/ports/** code, found: #{inspect(offenders)}"
  end

  test "packages/pincer_ports/lib/** does not define concrete Core defaults in code" do
    core_prefix = "Pincer." <> "Core."
    adapter_regex = Regex.compile!(Regex.escape(core_prefix) <> "[A-Za-z0-9_.]+\\.Adapter\\b")
    registry_name = core_prefix <> "Session." <> "Registry"

    files =
      "packages/pincer_ports/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.sort()

    assert files != [], "Expected packages/pincer_ports/lib/** to contain source files"

    offenders =
      files
      |> Enum.filter(fn file ->
        code = code_without_docs(file)
        Regex.match?(adapter_regex, code) or String.contains?(code, registry_name)
      end)

    assert offenders == [],
           "Expected no concrete Core adapter/registry defaults in packages/pincer_ports code, found: #{inspect(offenders)}"
  end

  test "lib/pincer/config.ex does not reference concrete Adapters or Storage modules in code" do
    file = "lib/pincer/config.ex"
    code = code_without_docs(file)

    forbidden = [
      "Pincer." <> "Adapters.",
      "Pincer." <> "Storage.",
      ~s("Pincer", "Adapters"),
      ~s("Pincer", "Storage")
    ]

    found = Enum.filter(forbidden, &String.contains?(code, &1))

    assert found == [],
           "Expected #{file} code not to reference #{inspect(found)}"
  end

  test "port dispatchers raise ArgumentError clearly when adapter env key is deleted or nil" do
    cases = [
      {:llm_adapter, &Pincer.Ports.LLM.list_providers/0},
      {:storage_adapter, &Pincer.Ports.Storage.query_history/0},
      {:cron_adapter, &Pincer.Ports.Cron.list_jobs/0},
      {:sandbox_adapter, &Pincer.Ports.Sandbox.adapter/0},
      {:session_registry, &Pincer.Ports.Session.registry/0},
      {:session_adapter, &Pincer.Ports.Session.adapter/0},
      {:ux_adapter, &Pincer.Ports.UX.adapter/0},
      {:project_adapter, &Pincer.Ports.Project.adapter/0},
      {:channel_policy_adapter, &Pincer.Ports.ChannelPolicy.adapter/0},
      {:streaming_adapter, &Pincer.Ports.Streaming.adapter/0}
    ]

    for {key, fun} <- cases, setting <- [:__delete__, nil] do
      with_env(key, setting, fn ->
        err = assert_raise ArgumentError, fun
        assert Exception.message(err) =~ Atom.to_string(key)
      end)
    end
  end

  defp code_without_docs(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> Macro.prewalk(fn
      {:@, _, [{attr, _, _}]} when attr in [:moduledoc, :doc] -> :ok
      node -> node
    end)
    |> Macro.to_string()
  end

  defp with_env(key, value_or_delete, fun) do
    prev = Application.fetch_env(:pincer, key)

    try do
      case value_or_delete do
        :__delete__ -> Application.delete_env(:pincer, key)
        val -> Application.put_env(:pincer, key, val)
      end

      fun.()
    after
      case prev do
        {:ok, old} -> Application.put_env(:pincer, key, old)
        :error -> Application.delete_env(:pincer, key)
      end
    end
  end
end
