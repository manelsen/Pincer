defmodule Pincer.Core.UX.MenuPolicy do
  @moduledoc """
  Core policy for channel command registration.

  Applies validation, normalization, deduplication and per-channel command caps
  so adapters can register safe command lists without channel-specific business
  logic scattered across modules.
  """

  @type channel :: :telegram | :discord
  @type issue :: String.t()

  @spec registerable_commands(channel(), [map()]) :: %{
          commands: [map()],
          issues: [issue()],
          dropped_count: non_neg_integer()
        }
  def registerable_commands(channel, commands) when is_list(commands) do
    spec = channel_spec(channel)

    {accepted, issues, dropped, _seen} =
      Enum.reduce(commands, {[], [], 0, MapSet.new()}, fn command, {acc, issues, dropped, seen} ->
        name = extract_field(command, :name)
        description = extract_field(command, :description)

        normalized_name = normalize_name(name)
        normalized_description = normalize_description(description)

        cond do
          normalized_name == "" ->
            {acc, issues ++ ["missing name"], dropped + 1, seen}

          not Regex.match?(spec.name_regex, normalized_name) ->
            {acc, issues ++ ["invalid name '#{normalized_name}'"], dropped + 1, seen}

          MapSet.member?(seen, normalized_name) ->
            {acc, issues ++ ["duplicate name '#{normalized_name}'"], dropped + 1, seen}

          normalized_description == "" ->
            {acc, issues ++ ["empty description for '#{normalized_name}'"], dropped + 1, seen}

          true ->
            {desc, desc_issue} = limit_description(normalized_description, spec.max_description)

            entry = %{
              spec.name_key => normalized_name,
              description: desc
            }

            issues = if desc_issue, do: issues ++ [desc_issue], else: issues
            {acc ++ [entry], issues, dropped, MapSet.put(seen, normalized_name)}
        end
      end)

    {capped, overflow} = cap_commands(accepted, spec.max_commands)

    overflow_issue =
      if overflow > 0 do
        [
          "#{channel} command limit (#{spec.max_commands}) reached; dropped #{overflow} overflow command(s)"
        ]
      else
        []
      end

    %{
      commands: capped,
      issues: issues ++ overflow_issue,
      dropped_count: dropped + overflow
    }
  end

  defp channel_spec(:telegram) do
    %{
      name_key: :command,
      name_regex: ~r/^[a-z0-9_]{1,32}$/,
      max_description: 256,
      max_commands: 100
    }
  end

  defp channel_spec(:discord) do
    %{
      name_key: :name,
      name_regex: ~r/^[a-z0-9_-]{1,32}$/,
      max_description: 100,
      max_commands: 100
    }
  end

  defp channel_spec(other),
    do: raise(ArgumentError, "unsupported channel for MenuPolicy: #{inspect(other)}")

  defp extract_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp extract_field(_, _), do: nil

  defp normalize_name(nil), do: ""

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_description(nil), do: ""

  defp normalize_description(description) do
    description
    |> to_string()
    |> String.trim()
  end

  defp limit_description(description, max_len) do
    if String.length(description) > max_len do
      {
        String.slice(description, 0, max_len),
        "description truncated to #{max_len} chars for command"
      }
    else
      {description, nil}
    end
  end

  defp cap_commands(commands, max_commands) do
    if length(commands) > max_commands do
      {Enum.take(commands, max_commands), length(commands) - max_commands}
    else
      {commands, 0}
    end
  end
end
