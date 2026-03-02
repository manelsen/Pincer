defmodule Pincer.Adapters.Tools.GitHub do
  @moduledoc """
  Native GitHub API integration tool for accessing user repositories.

  This tool provides secure, authenticated access to GitHub's REST API,
  specifically designed to retrieve repository information for the
  authenticated user. It ensures that all data belongs to the token owner,
  preventing unauthorized access to other users' information.

  ## Features

  - **Authenticated Access**: Uses personal access token for secure API calls
  - **Repository Listing**: Retrieve all, public, or private repositories
  - **Rich Metadata**: Returns name, full name, update timestamp, and URL

  ## Configuration

  Set the `GITHUB_PERSONAL_ACCESS_TOKEN` environment variable:

      export GITHUB_PERSONAL_ACCESS_TOKEN="ghp_xxxxxxxxxxxx"

  ### Creating a Token

  1. Go to GitHub Settings → Developer settings → Personal access tokens
  2. Generate new token (classic or fine-grained)
  3. Required scopes: `repo` (for private repos) or `public_repo` (read-only)

  ## Visibility Options

  | Value     | Description                              |
  |-----------|------------------------------------------|
  | `all`     | All repositories (default)               |
  | `public`  | Only public repositories                 |
  | `private` | Only private repositories                |

  ## API Rate Limits

  GitHub API has rate limits:
  - Authenticated: 5,000 requests/hour
  - Unauthenticated: 60 requests/hour (this tool requires auth)

  ## Examples

      # List all repositories
      iex> Pincer.Adapters.Tools.GitHub.execute(%{})
      {:ok, "Found 15 repositories:\\n\\n- **pincer** (user/pincer)..."}

      # List only private repositories
      iex> Pincer.Adapters.Tools.GitHub.execute(%{"visibility" => "private"})
      {:ok, "Found 3 repositories:\\n\\n- **secret-project** (user/secret-project)..."}

      # List only public repositories
      iex> Pincer.Adapters.Tools.GitHub.execute(%{"visibility" => "public"})
      {:ok, "Found 12 repositories:\\n\\n- **open-source-lib** (user/open-source-lib)..."}

  ## Security Considerations

  - Tokens are read from environment variables, never hardcoded
  - Uses Bearer token authentication over HTTPS
  - Only accesses the authenticated user's own data
  - Consider using fine-grained tokens with minimal permissions

  ## Error Handling

  Common errors and solutions:

  | Error                          | Cause                          |
  |--------------------------------|--------------------------------|
  | Token not configured           | Missing `GITHUB_PERSONAL_ACCESS_TOKEN` |
  | API returned status 401        | Invalid or expired token       |
  | API returned status 403        | Rate limit exceeded            |

  ## See Also

  - [GitHub REST API Documentation](https://docs.github.com/en/rest)
  - `Pincer.Ports.Tool` - Tool behaviour specification
  """

  @behaviour Pincer.Ports.Tool
  require Logger

  @github_api_url "https://api.github.com"
  @default_per_page 50

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

  @type visibility :: :all | :public | :private

  @doc """
  Returns the tool specification for LLM function calling.

  ## Returns

      %{
        name: "get_my_github_repos",
        description: "Lists all real repositories of the authenticated GitHub user...",
        parameters: %{
          type: "object",
          properties: %{
            visibility: %{type: "string", enum: ["all", "public", "private"], ...}
          }
        }
      }
  """
  @spec spec() :: spec()
  def spec do
    %{
      name: "get_my_github_repos",
      description:
        "Lists all real repositories of the authenticated GitHub user. Uses the environment token to ensure identity.",
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
  end

  @doc """
  Retrieves repositories for the authenticated GitHub user.

  Fetches repository information from GitHub's REST API using the configured
  personal access token. Results can be filtered by visibility.

  ## Parameters

    * `visibility` (optional) - Filter by repository visibility:
      - `"all"` (default) - All repositories
      - `"public"` - Only public repositories
      - `"private"` - Only private repositories

  ## Returns

    * `{:ok, formatted_list}` - Markdown-formatted list of repositories
    * `{:error, message}` - Error description

  ## Output Format

  Each repository is formatted as:

      - **name** (owner/name)
        Updated at: 2026-02-20T14:30:00Z
        URL: https://github.com/owner/name

  ## Examples

      iex> Pincer.Adapters.Tools.GitHub.execute(%{})
      {:ok, "Found 10 repositories:\\n\\n- **my-project** (user/my-project)..."}

      iex> Pincer.Adapters.Tools.GitHub.execute(%{"visibility" => "private"})
      {:ok, "Found 2 repositories:\\n\\n- **secret-repo** (user/secret-repo)..."}

      iex> Pincer.Adapters.Tools.GitHub.execute(%{})
      {:error, "GITHUB_PERSONAL_ACCESS_TOKEN not configured in environment"}
  """
  @spec execute(map()) :: execute_result()
  def execute(args) do
    token = System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
    visibility = Map.get(args, "visibility", "all")

    if is_nil(token) or token == "" do
      {:error, "GITHUB_PERSONAL_ACCESS_TOKEN not configured in environment"}
    else
      fetch_repositories(token, visibility)
    end
  end

  @doc false
  @spec fetch_repositories(String.t(), String.t()) :: execute_result()
  defp fetch_repositories(token, visibility) do
    url = "#{@github_api_url}/user/repos"
    params = [visibility: visibility, sort: "updated", per_page: @default_per_page]

    case Req.get(url,
           auth: {:bearer, token},
           params: params,
           headers: [{"Accept", "application/vnd.github.v3+json"}]
         ) do
      {:ok, %{status: 200, body: repos}} when is_list(repos) ->
        format_repository_list(repos)

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub API returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec format_repository_list([map()]) :: {:ok, String.t()}
  defp format_repository_list(repos) do
    summary =
      repos
      |> Enum.map(fn r ->
        "- **#{r["name"]}** (#{r["full_name"]})\n  Updated at: #{r["updated_at"]}\n  URL: #{r["html_url"]}"
      end)
      |> Enum.join("\n")

    {:ok, "Found #{length(repos)} repositories:\n\n" <> summary}
  end
end
