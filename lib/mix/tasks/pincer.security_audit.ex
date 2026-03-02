defmodule Mix.Tasks.Pincer.SecurityAudit do
  @moduledoc """
  Runs a security-focused audit for channels and gateway posture.

  Usage:

      mix pincer.security_audit
      mix pincer.security_audit --strict
      mix pincer.security_audit --config path/to/config.yaml
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Core.SecurityAudit

  @shortdoc "Security audit for auth, DM policy and gateway bind"

  @switches [
    config: :string,
    strict: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      invalid_flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.security_audit: #{invalid_flags}")
    end

    config_file = opts[:config] || "config.yaml"
    strict? = opts[:strict] == true
    report = SecurityAudit.run(config_file: config_file)

    print_report(report)

    cond do
      report.status == :error ->
        Mix.raise("Security audit found blocking security issues.")

      strict? and report.status == :warn ->
        Mix.raise("Security audit found security warnings in strict mode.")

      true ->
        :ok
    end
  end

  defp print_report(report) do
    Mix.shell().info("Pincer Security Audit Report")
    Mix.shell().info("Config: #{report.config_path}")
    Mix.shell().info("")

    Enum.each(report.checks, fn check ->
      level = check.severity |> to_string() |> String.upcase()
      Mix.shell().info("[#{level}] #{format_id(check.id)} - #{check.message}")
    end)

    Mix.shell().info("")

    Mix.shell().info(
      "Summary: ok=#{report.counts.ok} warn=#{report.counts.warn} error=#{report.counts.error} status: #{report.status}"
    )
  end

  defp format_id({left, right}), do: "#{left}:#{right}"
  defp format_id(id), do: to_string(id)
end
