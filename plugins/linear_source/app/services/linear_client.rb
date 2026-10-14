class LinearClient
  ENDPOINT = "https://api.linear.app/graphql"
  ISSUE_PAGE_SIZE = 100
  MAX_ISSUE_PAGES = 100

  def initialize(api_key:)
    @api_key = api_key
    @connection = Faraday.new(ENDPOINT) do |f|
      f.options.timeout = 30
      f.options.open_timeout = 10
    end
  end

  # Returns an array of issue hashes, or nil when rate-limited.
  def issues(team_id:, label_name: nil)
    query = label_name.present? ? ISSUES_WITH_LABEL_QUERY : ISSUES_QUERY
    variables = { teamId: team_id, first: ISSUE_PAGE_SIZE }
    variables[:labelName] = label_name if label_name.present?
    issues = []
    cursor = nil

    MAX_ISSUE_PAGES.times do
      result = execute(query, variables: variables.merge(after: cursor))
      return nil if result.nil?

      connection = result.dig("data", "issues") || {}
      issues.concat(connection["nodes"] || [])
      page_info = connection["pageInfo"] || {}
      return issues unless page_info["hasNextPage"]

      cursor = page_info["endCursor"]
      raise "Linear API returned a page without an end cursor" if cursor.blank?
    end

    raise "Linear issue pagination exceeded #{MAX_ISSUE_PAGES} pages"
  end

  # Returns the viewer data hash for credential validation, or nil when rate-limited.
  def viewer
    result = execute(VIEWER_QUERY, variables: {})
    return nil if result.nil?

    result.dig("data", "viewer")
  end

  # Returns an array of team hashes ({ "id" => ..., "name" => ... }), or [] when rate-limited.
  def teams
    result = execute(TEAMS_QUERY, variables: {})
    return [] if result.nil?

    result.dig("data", "teams", "nodes") || []
  end

  private

  def execute(query, variables: {})
    response = @connection.post do |req|
      req.headers["Authorization"] = @api_key
      req.headers["Content-Type"] = "application/json"
      req.body = JSON.generate(query: query, variables: variables)
    end

    if response.status == 429
      Rails.logger.warn("[LinearClient] Rate limited — skipping")
      return nil
    end

    unless response.status == 200
      raise "Linear API returned HTTP #{response.status}: #{response.body.to_s.truncate(200)}"
    end

    body = JSON.parse(response.body)
    errors = body["errors"]
    raise "Linear API error: #{errors.map { |e| e['message'] }.join(', ')}" if errors.present?

    body
  rescue Faraday::Error => e
    raise "Linear connection error: #{e.message}"
  end

  ISSUES_QUERY = <<~GQL.freeze
    query IssueList($teamId: String!, $first: Int!, $after: String) {
      issues(first: $first, after: $after, filter: {
        team: { id: { eq: $teamId } }
        state: { type: { nin: ["cancelled", "completed"] } }
      }) {
        nodes {
          id
          identifier
          title
          description
          state { type }
          labels { nodes { name } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  GQL

  ISSUES_WITH_LABEL_QUERY = <<~GQL.freeze
    query IssueListWithLabel($teamId: String!, $labelName: String!, $first: Int!, $after: String) {
      issues(first: $first, after: $after, filter: {
        team: { id: { eq: $teamId } }
        state: { type: { nin: ["cancelled", "completed"] } }
        labels: { name: { eq: $labelName } }
      }) {
        nodes {
          id
          identifier
          title
          description
          state { type }
          labels { nodes { name } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  GQL

  VIEWER_QUERY = <<~GQL.freeze
    query Viewer {
      viewer { id }
    }
  GQL

  TEAMS_QUERY = <<~GQL.freeze
    query Teams {
      teams { nodes { id name } }
    }
  GQL
end
