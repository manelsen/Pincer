defmodule Pincer.Adapters.Tools.GitHub do
  @moduledoc """
  GitHub REST API tool for Pincer agents.

  Provides authenticated access to GitHub: repositories, pull requests, issues,
  comments, commits, and code search.

  ## Configuration

      export GITHUB_PERSONAL_ACCESS_TOKEN="ghp_xxxxxxxxxxxx"

  Required scopes: `repo` (full access) or `public_repo` + `read:org` for public repos only.

  ## Actions

  | Action          | Description                                          |
  |-----------------|------------------------------------------------------|
  | `list_repos`    | List repositories of the authenticated user          |
  | `list_prs`      | List pull requests for a repository                  |
  | `list_issues`   | List issues for a repository                         |
  | `get_pr`        | Get details for a specific pull request              |
  | `get_issue`     | Get details for a specific issue                     |
  | `create_issue`  | Create a new issue                                   |
  | `comment`       | Add a comment to an issue or pull request            |
  | `search_code`   | Search code across GitHub repositories               |
  | `list_commits`  | List commits for a repository / branch               |

  The legacy spec `get_my_github_repos` is also exported for backward compatibility.
  """

  @behaviour Pincer.Ports.Tool

  require Logger

  @github_api "https://api.github.com"
  @default_per_page 30
  @gh_accept "application/vnd.github.v3+json"

  # ---------------------------------------------------------------------------
  # spec/0  — returns two specs: the new `github` tool + the legacy one
  # ---------------------------------------------------------------------------

  @impl true
  def spec do
    [
      %{
        name: "github",
        description:
          "Interacts with GitHub: list/search repos, PRs, issues, commits, create issues, add comments, search code.",
        parameters: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              description:
                "Action to perform: 'list_repos', 'list_prs', 'list_issues', 'get_pr', 'get_issue', 'create_issue', 'comment', 'search_code', 'list_commits'",
              enum: [
                "list_repos",
                "list_prs",
                "list_issues",
                "get_pr",
                "get_issue",
                "create_issue",
                "comment",
                "search_code",
                "list_commits"
              ]
            },
            repo: %{
              type: "string",
              description: "Repository in 'owner/name' format (required for most actions)"
            },
            number: %{
              type: "integer",
              description: "PR or issue number (required for 'get_pr', 'get_issue', 'comment')"
            },
            state: %{
              type: "string",
              description: "Filter by state: 'open', 'closed', 'all' (default: 'open')",
              enum: ["open", "closed", "all"]
            },
            title: %{
              type: "string",
              description: "Issue title (required for 'create_issue')"
            },
            body: %{
              type: "string",
              description: "Issue/comment body text"
            },
            labels: %{
              type: "string",
              description: "Comma-separated label names for filtering or creating issues"
            },
            query: %{
              type: "string",
              description: "Search query for 'search_code' (e.g. 'authenticate user repo:owner/name')"
            },
            branch: %{
              type: "string",
              description: "Branch name for 'list_commits' (default: default branch)"
            },
            visibility: %{
              type: "string",
              description: "Visibility filter for 'list_repos': 'all', 'public', 'private'",
              enum: ["all", "public", "private"]
            },
            per_page: %{
              type: "integer",
              description: "Results per page (max 100, default 30)"
            }
          },
          required: ["action"]
        }
      },
      # Legacy spec kept for backward compatibility
      %{
        name: "get_my_github_repos",
        description: "Lists repositories of the authenticated GitHub user (legacy — prefer 'github' tool with action='list_repos').",
        parameters: %{
          type: "object",
          properties: %{
            visibility: %{
              type: "string",
              enum: ["all", "public", "private"],
              description: "Filter by visibility (default: all)."
            }
          }
        }
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # execute/2
  # ---------------------------------------------------------------------------

  @impl true
  def execute(args, _context \\ %{}) do
    token = gh_client().token()

    if is_nil(token) or token == "" do
      {:error, "GITHUB_PERSONAL_ACCESS_TOKEN not configured in environment"}
    else
      dispatch(Map.get(args, "action", "list_repos"), args, token)
    end
  end

  # ---------------------------------------------------------------------------
  # Action dispatch
  # ---------------------------------------------------------------------------

  defp dispatch("list_repos", args, token) do
    visibility = Map.get(args, "visibility", "all")
    per_page = clamp_per_page(Map.get(args, "per_page", @default_per_page))

    case gh_get("/user/repos", token, visibility: visibility, sort: "updated", per_page: per_page) do
      {:ok, repos} when is_list(repos) ->
        lines =
          Enum.map(repos, fn r ->
            "- **#{r["name"]}** (`#{r["full_name"]}`) — #{r["description"] || "no description"}\n" <>
              "  Updated: #{r["updated_at"]}  URL: #{r["html_url"]}"
          end)

        {:ok, "Found #{length(repos)} repositories:\n\n" <> Enum.join(lines, "\n")}

      {:error, _} = err ->
        err
    end
  end

  # Legacy dispatch — same as list_repos
  defp dispatch(nil, args, token), do: dispatch("list_repos", args, token)

  defp dispatch("list_prs", %{"repo" => repo} = args, token) do
    state = Map.get(args, "state", "open")
    labels = Map.get(args, "labels")
    per_page = clamp_per_page(Map.get(args, "per_page", @default_per_page))
    params = [state: state, per_page: per_page] ++ if(labels, do: [labels: labels], else: [])

    case gh_get("/repos/#{repo}/pulls", token, params) do
      {:ok, prs} when is_list(prs) ->
        format_pr_list(prs, repo)

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("list_prs", _args, _token), do: {:error, "Missing required parameter: repo"}

  defp dispatch("list_issues", %{"repo" => repo} = args, token) do
    state = Map.get(args, "state", "open")
    labels = Map.get(args, "labels")
    per_page = clamp_per_page(Map.get(args, "per_page", @default_per_page))

    params =
      [state: state, per_page: per_page] ++
        if(labels, do: [labels: labels], else: [])

    case gh_get("/repos/#{repo}/issues", token, params) do
      {:ok, items} when is_list(items) ->
        # GitHub returns PRs mixed with issues; filter to actual issues only
        issues = Enum.reject(items, &Map.has_key?(&1, "pull_request"))
        format_issue_list(issues, repo)

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("list_issues", _args, _token), do: {:error, "Missing required parameter: repo"}

  defp dispatch("get_pr", %{"repo" => repo, "number" => number}, token) do
    case gh_get("/repos/#{repo}/pulls/#{number}", token, []) do
      {:ok, pr} when is_map(pr) -> {:ok, format_pr(pr)}
      {:error, _} = err -> err
    end
  end

  defp dispatch("get_pr", _args, _token),
    do: {:error, "Missing required parameters: repo, number"}

  defp dispatch("get_issue", %{"repo" => repo, "number" => number}, token) do
    case gh_get("/repos/#{repo}/issues/#{number}", token, []) do
      {:ok, issue} when is_map(issue) -> {:ok, format_issue(issue)}
      {:error, _} = err -> err
    end
  end

  defp dispatch("get_issue", _args, _token),
    do: {:error, "Missing required parameters: repo, number"}

  defp dispatch("create_issue", %{"repo" => repo, "title" => title} = args, token) do
    body_text = Map.get(args, "body", "")
    labels = args |> Map.get("labels", "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    payload = %{"title" => title, "body" => body_text} |> maybe_put("labels", labels)

    case gh_post("/repos/#{repo}/issues", token, payload) do
      {:ok, issue} when is_map(issue) ->
        {:ok, "Issue ##{issue["number"]} created: #{issue["html_url"]}"}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("create_issue", _args, _token),
    do: {:error, "Missing required parameters: repo, title"}

  defp dispatch("comment", %{"repo" => repo, "number" => number, "body" => body}, token) do
    case gh_post("/repos/#{repo}/issues/#{number}/comments", token, %{"body" => body}) do
      {:ok, comment} when is_map(comment) ->
        {:ok, "Comment posted: #{comment["html_url"]}"}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("comment", _args, _token),
    do: {:error, "Missing required parameters: repo, number, body"}

  defp dispatch("search_code", %{"query" => query} = args, token) do
    per_page = clamp_per_page(Map.get(args, "per_page", @default_per_page))

    case gh_get("/search/code", token, q: query, per_page: per_page) do
      {:ok, %{"items" => items, "total_count" => total}} ->
        lines =
          Enum.map(items, fn item ->
            "- `#{item["path"]}` in **#{item["repository"]["full_name"]}**\n  #{item["html_url"]}"
          end)

        {:ok, "#{total} result(s) (showing #{length(items)}):\n\n" <> Enum.join(lines, "\n")}

      {:ok, _other} ->
        {:ok, "No results found."}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("search_code", _args, _token),
    do: {:error, "Missing required parameter: query"}

  defp dispatch("list_commits", %{"repo" => repo} = args, token) do
    branch = Map.get(args, "branch")
    per_page = clamp_per_page(Map.get(args, "per_page", @default_per_page))
    params = [per_page: per_page] ++ if(branch, do: [sha: branch], else: [])

    case gh_get("/repos/#{repo}/commits", token, params) do
      {:ok, commits} when is_list(commits) ->
        lines =
          Enum.map(commits, fn c ->
            sha = String.slice(c["sha"] || "", 0, 7)
            msg = get_in(c, ["commit", "message"]) |> first_line()
            author = get_in(c, ["commit", "author", "name"]) || "unknown"
            date = get_in(c, ["commit", "author", "date"]) || ""
            "- `#{sha}` #{msg} — #{author} (#{date})"
          end)

        {:ok, "#{length(commits)} commits:\n\n" <> Enum.join(lines, "\n")}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch("list_commits", _args, _token),
    do: {:error, "Missing required parameter: repo"}

  defp dispatch(unknown, _args, _token),
    do: {:error, "Unknown github action: #{unknown}"}

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp gh_get(path, token, params) do
    url = @github_api <> path

    case Req.get(url,
           auth: {:bearer, token},
           params: params,
           headers: [{"Accept", @gh_accept}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        message = extract_gh_error(body, status)
        Logger.warning("[GITHUB] GET #{path} → #{status}: #{message}")
        {:error, message}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end

  defp gh_post(path, token, payload) do
    url = @github_api <> path

    case Req.post(url,
           auth: {:bearer, token},
           json: payload,
           headers: [{"Accept", @gh_accept}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        message = extract_gh_error(body, status)
        Logger.warning("[GITHUB] POST #{path} → #{status}: #{message}")
        {:error, message}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Formatters
  # ---------------------------------------------------------------------------

  defp format_pr_list(prs, repo) do
    lines =
      Enum.map(prs, fn pr ->
        "- ##{pr["number"]} **#{pr["title"]}** [#{pr["state"]}] by #{get_in(pr, ["user", "login"])}\n  #{pr["html_url"]}"
      end)

    {:ok, "#{length(prs)} PR(s) in #{repo}:\n\n" <> Enum.join(lines, "\n")}
  end

  defp format_issue_list(issues, repo) do
    lines =
      Enum.map(issues, fn i ->
        labels = i["labels"] |> Enum.map(& &1["name"]) |> Enum.join(", ")
        label_str = if labels != "", do: " [#{labels}]", else: ""
        "- ##{i["number"]} **#{i["title"]}** [#{i["state"]}]#{label_str}\n  #{i["html_url"]}"
      end)

    {:ok, "#{length(issues)} issue(s) in #{repo}:\n\n" <> Enum.join(lines, "\n")}
  end

  defp format_pr(pr) do
    """
    PR ##{pr["number"]}: #{pr["title"]}
    State: #{pr["state"]} | Mergeable: #{pr["mergeable"]}
    Author: #{get_in(pr, ["user", "login"])}
    Branch: #{get_in(pr, ["head", "ref"])} → #{get_in(pr, ["base", "ref"])}
    URL: #{pr["html_url"]}
    Additions: +#{pr["additions"]}  Deletions: -#{pr["deletions"]}  Changed files: #{pr["changed_files"]}

    #{pr["body"] || "(no description)"}
    """
  end

  defp format_issue(issue) do
    labels = issue["labels"] |> Enum.map(& &1["name"]) |> Enum.join(", ")

    """
    Issue ##{issue["number"]}: #{issue["title"]}
    State: #{issue["state"]} | Labels: #{labels}
    Author: #{get_in(issue, ["user", "login"])}
    URL: #{issue["html_url"]}

    #{issue["body"] || "(no description)"}
    """
  end

  defp extract_gh_error(%{"message" => msg}, _status), do: msg
  defp extract_gh_error(_, status), do: "GitHub API error #{status}"

  defp first_line(nil), do: ""
  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.slice(0, 80)

  defp clamp_per_page(n) when is_integer(n), do: min(max(n, 1), 100)
  defp clamp_per_page(_), do: @default_per_page

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Injectable HTTP client (for testing)
  # ---------------------------------------------------------------------------

  defp gh_client, do: Application.get_env(:pincer, :github_client, __MODULE__.DefaultClient)

  defmodule DefaultClient do
    def token, do: System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
  end
end
