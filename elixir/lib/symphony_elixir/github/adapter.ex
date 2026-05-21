defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.

  This adapter intentionally keeps GitHub mapping simple: `tracker.project_slug`
  is `owner/repo`, workflow states are labels, and issue IDs are issue numbers.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Issue}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    fetch_issues_by_states(tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, config} <- github_config(),
         states <- normalize_state_names(state_names) do
      fetch_each_state(config, states)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, config} <- github_config() do
      fetch_each_issue_id(config, Config.settings!().tracker, Enum.uniq(issue_ids))
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, config} <- github_config(),
         {:ok, _response} <-
           request(config, :post, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}/comments", %{body: body}) do
      :ok
    end
  end

  @spec add_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_issue_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    labels = normalize_state_names(labels)

    if labels == [] do
      :ok
    else
      with {:ok, config} <- github_config(),
           :ok <- ensure_labels_exist(config, labels),
           {:ok, _response} <-
             request(config, :post, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}/labels", %{
               labels: labels
             }) do
        :ok
      end
    end
  end

  @spec remove_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def remove_issue_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    with {:ok, config} <- github_config() do
      labels
      |> normalize_state_names()
      |> Enum.reduce_while(:ok, fn label, :ok ->
        encoded_label = URI.encode(label, &URI.char_unreserved?/1)

        case request(config, :delete, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}/labels/#{encoded_label}") do
          {:ok, _response} -> {:cont, :ok}
          {:error, {:github_api_status, 404, _response_body}} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ensure_labels_exist(config, labels) when is_list(labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case request(config, :post, "/repos/#{config.owner}/#{config.repo}/labels", %{
             name: label,
             color: "ededed",
             description: "Managed by Symphony issue lifecycle automation"
           }) do
        {:ok, _response} -> {:cont, :ok}
        {:error, {:github_api_status, 422, _response_body}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, config} <- github_config(),
         {:ok, issue} <- request(config, :get, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}"),
         existing_labels <- label_names(issue),
         removable <- configured_state_labels(tracker),
         next_labels <- [state_name | Enum.reject(existing_labels, &label_matches_any?(&1, removable))],
         {:ok, _response} <-
           request(config, :put, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}/labels", %{
             labels: Enum.uniq(next_labels)
           }) do
      maybe_update_issue_open_closed_state(config, issue_id, state_name, tracker)
    end
  end

  @spec sync_issue_completion(String.t()) :: :ok | {:error, term()}
  def sync_issue_completion(issue_id) when is_binary(issue_id) do
    tracker = Config.settings!().tracker

    with {:ok, config} <- github_config(),
         {:ok, completion_state} <- completion_state(tracker) do
      case merged_closing_pull_request?(config, issue_id) do
        {:ok, true} -> update_issue_state(issue_id, completion_state)
        {:ok, false} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :no_completion_state -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_each_state(config, states) do
    states
    |> Enum.reduce_while({:ok, []}, &fetch_state_reducer(config, states, &1, &2))
    |> case do
      {:ok, issues} -> {:ok, dedupe_issues(issues)}
      error -> error
    end
  end

  defp merged_closing_pull_request?(config, issue_id) do
    issue_id
    |> closing_search_queries(config)
    |> Enum.reduce_while({:ok, false}, fn query, {:ok, false} ->
      path = "/search/issues?" <> URI.encode_query(%{q: query, per_page: 1})

      case request(config, :get, path) do
        {:ok, %{"total_count" => count}} when is_integer(count) and count > 0 -> {:halt, {:ok, true}}
        {:ok, _response} -> {:cont, {:ok, false}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp closing_search_queries(issue_id, config) do
    issue_ref = "##{issue_id}"
    qualified_ref = "#{config.owner}/#{config.repo}#{issue_ref}"

    ["closes", "close", "closed", "fixes", "fix", "fixed", "resolves", "resolve", "resolved"]
    |> Enum.flat_map(fn keyword ->
      [
        ~s(repo:#{config.owner}/#{config.repo} is:pr is:merged in:body "#{keyword} #{issue_ref}"),
        ~s(repo:#{config.owner}/#{config.repo} is:pr is:merged in:body "#{keyword} #{qualified_ref}")
      ]
    end)
  end

  defp fetch_state_reducer(config, states, state, {:ok, acc}) do
    case fetch_state_pages(config, state, states, 1, []) do
      {:ok, issues} -> {:cont, {:ok, issues ++ acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), [String.t()], [String.t()]) :: Issue.t() | nil
  def normalize_issue_for_test(issue, active_states, terminal_states) when is_map(issue) and is_list(active_states) and is_list(terminal_states) do
    normalize_issue(issue, %{active_states: active_states, terminal_states: terminal_states})
  end

  defp fetch_each_issue_id(config, tracker, issue_ids) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, &fetch_issue_id_reducer(config, tracker, &1, &2))
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(Enum.reject(issues, &is_nil/1))}
      error -> error
    end
  end

  defp fetch_issue_id_reducer(config, tracker, issue_id, {:ok, acc}) do
    case request(config, :get, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}") do
      {:ok, issue} -> {:cont, {:ok, [normalize_issue(issue, tracker) | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp fetch_state_pages(config, state, all_states, page, acc) do
    path = "/repos/#{config.owner}/#{config.repo}/issues?state=all&per_page=100&page=#{page}&labels=#{URI.encode(state)}"
    tracker = Config.settings!().tracker

    with {:ok, issues} <- request(config, :get, path) do
      normalized =
        issues
        |> Enum.reject(&pull_request?/1)
        |> Enum.map(&normalize_issue(&1, tracker))
        |> Enum.reject(&is_nil/1)

      case normalized do
        [] when issues == [] -> {:ok, Enum.reverse(acc)}
        _ -> fetch_state_pages(config, state, all_states, page + 1, Enum.reverse(normalized) ++ acc)
      end
    end
  end

  defp dedupe_issues(issues) do
    issues
    |> Enum.reduce(%{}, fn %Issue{id: id} = issue, acc -> Map.put_new(acc, id, issue) end)
    |> Map.values()
    |> Enum.sort_by(fn %Issue{priority: priority, created_at: created_at} ->
      {priority || 99, created_at || ~U[9999-12-31 23:59:59Z]}
    end)
  end

  defp github_config do
    tracker = Config.settings!().tracker

    with {:ok, token} <- required_value(tracker.api_key, :missing_github_token),
         {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug) do
      endpoint =
        tracker.endpoint
        |> case do
          nil -> "https://api.github.com"
          "https://api.linear.app/graphql" -> "https://api.github.com"
          value -> String.trim(value)
        end
        |> String.trim_trailing("/")

      {:ok, %{endpoint: endpoint, token: token, owner: owner, repo: repo}}
    end
  end

  defp request(config, method, path, body \\ nil) do
    request_opts = [
      url: config.endpoint <> path,
      method: method,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer #{config.token}"},
        {"user-agent", "third-space-symphony/1.0"},
        {"x-github-api-version", "2022-11-28"}
      ]
    ]

    request_opts =
      if is_nil(body) do
        request_opts
      else
        Keyword.put(request_opts, :json, body)
      end

    request_opts =
      :symphony_elixir
      |> Application.get_env(:github_req_options, [])
      |> Keyword.merge(request_opts)

    case Req.request(request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 -> {:ok, response_body}
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_api_status, status, response_body}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp normalize_issue(issue, tracker) when is_map(issue) do
    labels = label_names(issue)
    issue_state = github_issue_state(issue, labels, tracker)
    tracker_flags = github_tracker_flags(issue, labels, tracker)

    %Issue{
      id: issue["number"] |> to_string(),
      identifier: "GH-#{issue["number"]}",
      title: issue["title"],
      description: issue["body"],
      priority: priority_from_labels(labels),
      state: issue_state,
      branch_name: nil,
      url: issue["html_url"],
      assignee_id: get_in(issue, ["assignee", "login"]),
      tracker_flags: tracker_flags,
      blocked_by: [],
      labels: labels,
      assigned_to_worker: true,
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp normalize_issue(_issue, _tracker), do: nil

  defp github_tracker_flags(issue, labels, tracker) do
    active_labels = matching_state_labels(labels, tracker.active_states)
    terminal_labels = matching_state_labels(labels, tracker.terminal_states)

    %{
      github_open?: !github_issue_closed?(issue),
      active_labels: active_labels,
      terminal_labels: terminal_labels,
      active_terminal_label_conflict?: !github_issue_closed?(issue) and active_labels != [] and terminal_labels != []
    }
  end

  defp github_issue_state(issue, labels, tracker) do
    terminal_label = matching_state_label(labels, tracker.terminal_states)
    active_label = matching_state_label(labels, tracker.active_states)

    cond do
      github_issue_closed?(issue) ->
        terminal_label || "Closed"

      is_binary(terminal_label) ->
        terminal_label

      is_binary(active_label) ->
        active_label

      true ->
        open_closed_state(issue["state"])
    end
  end

  defp label_names(issue) when is_map(issue) do
    issue
    |> Map.get("labels", [])
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp matching_state_label(labels, states) do
    Enum.find(states, fn state -> label_matches_any?(state, labels) end)
  end

  defp matching_state_labels(labels, states) do
    Enum.filter(states, fn state -> label_matches_any?(state, labels) end)
  end

  defp configured_state_labels(tracker), do: normalize_state_names(tracker.active_states ++ tracker.terminal_states)

  defp label_matches_any?(label, labels) do
    normalized = normalize_label(label)
    Enum.any?(labels, &(normalize_label(&1) == normalized))
  end

  defp normalize_state_names(states) do
    states
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_label(label) when is_binary(label) do
    label |> String.trim() |> String.downcase()
  end

  defp normalize_label(_label), do: ""

  defp maybe_update_issue_open_closed_state(config, issue_id, state_name, tracker) do
    cond do
      closable_terminal_state?(state_name) ->
        patch_issue_state(config, issue_id, "closed")

      label_matches_any?(state_name, tracker.active_states) ->
        patch_issue_state(config, issue_id, "open")

      true ->
        :ok
    end
  end

  defp completion_state(tracker) do
    case preferred_terminal_state(tracker.terminal_states, ["done", "closed"]) do
      state when is_binary(state) -> {:ok, state}
      _ -> :no_completion_state
    end
  end

  defp preferred_terminal_state(states, preferred_states) when is_list(states) do
    Enum.find(states, fn state ->
      Enum.any?(preferred_states, &(normalize_label(state) == &1))
    end)
  end

  defp patch_issue_state(config, issue_id, state) do
    request(config, :patch, "/repos/#{config.owner}/#{config.repo}/issues/#{issue_id}", %{state: state})
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_repo_slug(slug) when is_binary(slug) do
    case String.split(String.trim(slug), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner, repo}
      _ -> {:error, :missing_github_repo_slug}
    end
  end

  defp parse_repo_slug(_slug), do: {:error, :missing_github_repo_slug}

  defp required_value(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      normalized -> {:ok, normalized}
    end
  end

  defp required_value(_value, error), do: {:error, error}

  defp pull_request?(issue) when is_map(issue), do: is_map(issue["pull_request"])
  defp pull_request?(_issue), do: false

  defp github_issue_closed?(%{"state" => "closed"}), do: true
  defp github_issue_closed?(_issue), do: false

  defp open_closed_state("closed"), do: "Closed"
  defp open_closed_state(_state), do: "Open"

  defp closable_terminal_state?(state_name) do
    label_matches_any?(state_name, ["Done", "Closed", "Canceled", "Cancelled"])
  end

  defp priority_from_labels(labels) do
    cond do
      label_matches_any?("priority:urgent", labels) -> 1
      label_matches_any?("priority:high", labels) -> 2
      label_matches_any?("priority:medium", labels) -> 3
      label_matches_any?("priority:low", labels) -> 4
      true -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
