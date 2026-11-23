defmodule Pincer.Core.Skills.Guard do
  @moduledoc """
  Static security scanner and structural validator for skills (`SKILL.md`).

  Inspired by Nous Research Hermes Agent's `tools/skills_guard.py` and
  `tools/skill_manager_tool.py`:
  - Enforces strict slug format and prompt size budgets
  - Scans markdown and embedded commands for exfiltration, destructive payloads,
    agent-config tampering (`persistence`), prompt injection, and invisible Unicode chars
  - Applies a **fail-closed** policy for agent-generated skills before disk write
  """

  alias Pincer.Core.Skills.Manifest

  @slug_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @default_max_description_chars 512
  @default_max_body_chars 16_384

  @loopback_url_re ~r/https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?:[:\/\s?#]|$)/i
  @negated_modify_re ~r/\b(?:do\s+not|don't|never|not|avoid)\b[^\n]{0,30}\b(?:edit|modify|write|overwrite|append|replace|update|alter)\b/i

  @type finding :: %{
          id: atom(),
          severity: :critical | :high | :medium,
          category: :exfiltration | :destructive | :persistence | :injection,
          description: String.t(),
          line: pos_integer(),
          match: String.t()
        }

  @type scan_result :: %{
          verdict: :safe | :caution | :dangerous,
          findings: [finding()]
        }

  # Regex structs contain compiled-pattern references that Elixir 1.18.6
  # refuses to escape out of a module attribute, so build the rule list inside
  # a function and pass it once per scan.
  defp rules do
    [
      %{
        id: :env_exfil_http,
        severity: :critical,
        category: :exfiltration,
        regex:
          ~r/(?:curl|wget|fetch|httpx?\.|requests\.)[^\n]*\$\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)S?\b/i,
        description: "HTTP command/call interpolating secret environment variable",
        exempt: :loopback_url
      },
      %{
        id: :credential_dir_access,
        severity: :critical,
        category: :exfiltration,
        regex: ~r/(?:\$HOME|~)\/\.(?:ssh|aws|gnupg|kube|docker)\b/,
        description: "References sensitive user credential directory"
      },
      %{
        id: :read_secrets_file,
        severity: :critical,
        category: :exfiltration,
        regex:
          ~r/\bcat\s+(?!>)[^\n]*(?:\.env\b|credentials\b|\.netrc\b|\.pgpass\b|\.npmrc\b|\.pypirc\b|id_(?:rsa|ed25519|ecdsa|dsa)(?!\.pub))/i,
        description: "Reads known credential or private key file"
      },
      %{
        id: :dump_all_env,
        severity: :critical,
        category: :exfiltration,
        regex: ~r/\bprintenv\b|(?<![A-Za-z0-9_])env\s*\|(?!\|)/i,
        description: "Dumps environment variables"
      },
      %{
        id: :dns_exfil,
        severity: :critical,
        category: :exfiltration,
        regex: ~r/\b(?:dig|nslookup|host)\s+[^\n]*\$(?:\{[^}\s]*\}|\([^\n]*\)|\w+)[^\s]*\.[a-z]/i,
        description: "DNS query with variable interpolation (potential DNS exfiltration)"
      },
      %{
        id: :md_image_exfil,
        severity: :critical,
        category: :exfiltration,
        regex: ~r/!\[[^\]]*\]\(https?:\/\/[^\)]*\$\{?/i,
        description: "Markdown image URL with variable interpolation"
      },
      %{
        id: :pipe_to_shell,
        severity: :critical,
        category: :destructive,
        regex: ~r/(?:curl|wget)\b[^\n]*\|\s*(?:sudo\s+)?(?:ba|z|k|da)?sh\b/i,
        description: "Downloads remote script and pipes directly to shell"
      },
      %{
        id: :rm_rf_root,
        severity: :critical,
        category: :destructive,
        regex:
          ~r/\brm\s+[^\n]*-(?:[a-zA-Z]*r[a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*r)\s+(?:\/\s*$|\/(?:\s|--no-preserve-root|\*)|~\/?\*)/,
        description: "Destructive recursive delete targeting root or home directory"
      },
      %{
        id: :reverse_shell,
        severity: :critical,
        category: :destructive,
        regex: ~r/\bnc\b[^\n]*\s-e\s|\bbash\s+-i\s+>&\s+\/dev\/tcp\//i,
        description: "Reverse shell invocation pattern"
      },
      %{
        id: :agent_config_shell_write,
        severity: :critical,
        category: :persistence,
        regex:
          ~r/(?:>>|\S\s*>|\bsed\b[^\n]*\s-[A-Za-z]*i|\btee\s+(?:-a\s+)?)[^\n]*\b(?:SOUL\.md|IDENTITY\.md|AGENTS\.md|CLAUDE\.md|USER\.md|STYLE\.md|config\.yaml|\.cursorrules)\b/,
        description: "Shell command modifies protected agent config or persona file"
      },
      %{
        id: :agent_config_imperative,
        severity: :critical,
        category: :persistence,
        regex:
          ~r/(?:^\s*(?:[-*+]\s+|\d+[.)]\s+)?|\b(?:you\s+(?:must|should|need\s+to)|please|always|make\s+sure\s+to)\s+)\b(?:edit|modify|write|overwrite|append|replace|update|alter)\b[^\n]{0,60}\b(?:SOUL\.md|IDENTITY\.md|AGENTS\.md|CLAUDE\.md|USER\.md|STYLE\.md|config\.yaml|\.cursorrules)\b/i,
        description: "Instruction directs modification of protected agent config or persona file",
        exempt: :negated_modify
      },
      %{
        id: :prompt_injection,
        severity: :critical,
        category: :injection,
        regex:
          ~r/\b(?:ignore|disregard|forget)\s+(?:all\s+)?(?:previous|prior|above|system)\s+(?:instructions|prompts?|rules?)\b|\bbypass\s+approval\b/i,
        description: "Prompt-injection or approval-bypass instruction"
      },
      %{
        id: :invisible_unicode,
        severity: :critical,
        category: :injection,
        regex: ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u,
        description: "Hidden or bidirectional Unicode control characters"
      }
    ]
  end

  @doc "Validates a skill directory/manifest slug."
  @spec validate_slug(term()) :: :ok | {:error, :invalid_skill_slug}
  def validate_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_regex, slug) do
      :ok
    else
      {:error, :invalid_skill_slug}
    end
  end

  def validate_slug(_), do: {:error, :invalid_skill_slug}

  @doc """
  Scans raw skill markdown content and returns verdict and matched findings.
  """
  @spec scan(String.t()) :: scan_result()
  def scan(content) when is_binary(content) do
    rules = rules()

    findings =
      content
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} -> scan_line(line, line_no, rules) end)

    %{
      verdict: compute_verdict(findings),
      findings: findings
    }
  end

  @doc """
  Validates slug, manifest frontmatter, size budgets, and security posture (fail-closed).
  """
  @spec validate_and_scan(String.t(), String.t(), keyword()) ::
          {:ok, %{manifest: Manifest.t(), scan: scan_result()}} | {:error, term()}
  def validate_and_scan(slug, content, opts \\ []) when is_binary(content) do
    max_desc = Keyword.get(opts, :max_description_chars, @default_max_description_chars)
    max_body = Keyword.get(opts, :max_body_chars, @default_max_body_chars)
    allow_caution? = Keyword.get(opts, :allow_caution, false)

    with :ok <- validate_slug(slug),
         {:ok, manifest} <- Manifest.parse(content),
         :ok <- validate_name_match(slug, manifest.name),
         :ok <- validate_description(manifest.description, max_desc),
         :ok <- validate_body(manifest.body, max_body) do
      scan_result = scan(content)

      if allowed_verdict?(scan_result.verdict, allow_caution?) do
        {:ok, %{manifest: manifest, scan: scan_result}}
      else
        {:error, {:security_blocked, scan_result.findings}}
      end
    end
  end

  @doc false
  def loopback_exempt?(line), do: Regex.match?(@loopback_url_re, line)

  @doc false
  def negated_modify?(line), do: Regex.match?(@negated_modify_re, line)

  # --- Private ---

  defp exempt?(nil, _line), do: false
  defp exempt?(:loopback_url, line), do: loopback_exempt?(line)
  defp exempt?(:negated_modify, line), do: negated_modify?(line)

  defp scan_line(line, line_no, rules) do
    Enum.reduce(rules, [], fn rule, acc ->
      case Regex.run(rule.regex, line) do
        [matched | _] ->
          if exempt?(Map.get(rule, :exempt), line) do
            acc
          else
            finding = %{
              id: rule.id,
              severity: rule.severity,
              category: rule.category,
              description: rule.description,
              line: line_no,
              match: String.slice(matched, 0, 120)
            }

            [finding | acc]
          end

        nil ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp compute_verdict([]), do: :safe

  defp compute_verdict(findings) do
    critical_count = Enum.count(findings, &(&1.severity == :critical))
    high_count = Enum.count(findings, &(&1.severity == :high))

    cond do
      critical_count > 0 or high_count >= 2 -> :dangerous
      true -> :caution
    end
  end

  defp allowed_verdict?(:safe, _allow_caution?), do: true
  defp allowed_verdict?(:caution, true), do: true
  defp allowed_verdict?(_, _), do: false

  defp validate_name_match(slug, slug), do: :ok
  defp validate_name_match(_, _), do: {:error, :slug_name_mismatch}

  defp validate_description(desc, max_len) when is_binary(desc) do
    trimmed = String.trim(desc)

    cond do
      trimmed == "" -> {:error, :missing_description}
      String.length(trimmed) > max_len -> {:error, :description_too_long}
      true -> :ok
    end
  end

  defp validate_description(_, _), do: {:error, :missing_description}

  defp validate_body(body, max_len) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" -> {:error, :empty_skill_body}
      String.length(trimmed) > max_len -> {:error, :body_too_long}
      true -> :ok
    end
  end

  defp validate_body(_, _), do: {:error, :empty_skill_body}
end
