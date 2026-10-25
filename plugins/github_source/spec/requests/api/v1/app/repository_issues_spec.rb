require "rails_helper"

RSpec.describe "API: repository GitHub issues", :ci_only, type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def encoded_query_filter(value)
    tree = { "and" => [ { "field" => "query", "op" => "contains", "value" => value } ] }
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  def encoded_filter(chips)
    tree = { "and" => chips }
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  def fake_issue(repository:, number:, title: "Fix something", state: "open", labels: [], body: nil, user_login: "alice", created_at: 1.day.ago)
    GithubIssue.where(repository: repository).create!(
      github_id: number + 10_000,
      number: number,
      title: title,
      state: state,
      html_url: "https://github.com/acme/widgets/issues/#{number}",
      body: body,
      github_created_at: created_at,
      author_login: user_login,
      labels: labels.map { |name| { "name" => name, "color" => "0075ca" } },
      synced_at: Time.current
    )
  end

  def stub_no_linked_pull_requests(client)
    allow(client).to receive(:linked_open_prs_for_issues).and_return({})
  end


  it "returns repository GitHub issues for the requested smart folder" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    open_issue = fake_issue(repository: repository, number: 5, title: "Open one", labels: [])
    closed_issue = fake_issue(repository: repository, number: 7, title: "Fix the forum", state: "closed", labels: [ "syrus", "bug" ], body: "Line one\nLine two")
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ open_issue ])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([ closed_issue ])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "closed" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["folder"]).to eq("closed")
    expect(body["issue_count"]).to eq(1)
    expect(body["issues"]).to contain_exactly(include(
      "number" => 7,
      "title" => "Fix the forum",
      "body_excerpt" => "Line one Line two",
      "user_login" => "alice",
      "delegated" => true,
      "labels" => include({ "name" => "bug", "color" => "0075ca" })
    ))
    expect(body["folder_counts"]).to eq({ "inbox" => 1, "delegated" => 0, "open" => 1, "closed" => 1 })
    expect(body.dig("paths", "app_delegate_issue_path")).to eq("/api/v1/app/repositories/#{repository.id}/issues/delegate")
    expect(body.dig("folder_paths", "open")).to eq("/repositories/#{repository.id}/plugin/issues?folder=open")
  end


  it "partitions open issues into the inbox and delegated smart folders" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    inbox_issue = fake_issue(repository: repository, number: 1, title: "Needs triage", labels: [])
    delegated_issue = fake_issue(repository: repository, number: 2, title: "Already delegated", labels: [ "syrus" ])
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ inbox_issue, delegated_issue ])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "inbox" }

    body = parse_body
    expect(body["issues"].map { |issue| issue["number"] }).to eq([ 1 ])
    expect(body["folder_counts"]).to eq({ "inbox" => 1, "delegated" => 1, "open" => 2, "closed" => 0 })
  end


  it "filters issues by a search query within the active folder without changing other folder counts" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    matching = fake_issue(repository: repository, number: 1, title: "Fix the forum", labels: [])
    other = fake_issue(repository: repository, number: 2, title: "Unrelated", labels: [])
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ matching, other ])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "open", q: encoded_query_filter("forum") }

    body = parse_body
    expect(body["query"]).to eq("forum")
    expect(body["filter"]).to eq({ "and" => [ { "field" => "query", "op" => "contains", "value" => "forum" } ] })
    expect(body["issue_count"]).to eq(1)
    expect(body["issues"].map { |issue| issue["number"] }).to eq([ 1 ])
    expect(body["folder_counts"]["open"]).to eq(2)
  end


  it "exposes the FilterBar schema for the issues search chip" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues"

    fields = parse_body["filter_schema"].index_by { |field| field["field"] }
    expect(fields.fetch("query")).to include("free_text_search" => true, "bucket" => "string")
    expect(fields.keys).to include("author", "label", "delegated", "state")
  end


  it "filters issues by author, label, delegated state, and issue state" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    matching = fake_issue(repository: repository, number: 1, title: "Matching", labels: [ "syrus", "bug" ], user_login: "ada")
    other_author = fake_issue(repository: repository, number: 2, title: "Wrong author", labels: [ "syrus", "bug" ], user_login: "grace")
    other_label = fake_issue(repository: repository, number: 3, title: "Wrong label", labels: [ "syrus", "feature" ], user_login: "ada")
    not_delegated = fake_issue(repository: repository, number: 4, title: "Not delegated", labels: [ "bug" ], user_login: "ada")
    closed = fake_issue(repository: repository, number: 5, title: "Closed", state: "closed", labels: [ "syrus", "bug" ], user_login: "ada")
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ matching, other_author, other_label, not_delegated ])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([ closed ])
    allow(GithubClient).to receive(:for).and_return(client)

    q = encoded_filter([
      { "field" => "author", "op" => "contains", "value" => "ada" },
      { "field" => "label", "op" => "contains", "value" => "bug" },
      { "field" => "delegated", "op" => "is", "value" => "true" },
      { "field" => "state", "op" => "is", "value" => "open" }
    ])
    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "open", q: q }

    body = parse_body
    expect(body["issues"].map { |issue| issue["number"] }).to eq([ 1 ])
    expect(body["issue_count"]).to eq(1)
    expect(body["folder_counts"]).to eq({ "inbox" => 1, "delegated" => 3, "open" => 4, "closed" => 1 })
  end


  it "sorts issues by requested columns before pagination" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    older = fake_issue(repository: repository, number: 1, title: "Zebra", created_at: 2.days.ago)
    newer = fake_issue(repository: repository, number: 2, title: "Alpha", created_at: 1.hour.ago)
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ older, newer ])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "open", sort: "title", direction: "asc" }

    body = parse_body
    expect(body["sort"]).to eq({ "column" => "title", "direction" => "asc" })
    expect(body["issues"].map { |issue| issue["number"] }).to eq([ 2, 1 ])
  end


  it "falls back to the closed folder for legacy state=closed links" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    allow(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { state: "closed" }

    expect(parse_body["folder"]).to eq("closed")
  end


  it "distinguishes an unsynchronized empty cache without consulting GitHub" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    repository.update_columns(last_poll_status: "ok", last_poll_started_at: 5.minutes.ago)
    expect(GithubClient).not_to receive(:for)

    get "/api/v1/app/repositories/#{repository.id}/issues"

    expect(response).to have_http_status(:ok)
    expect(parse_body["issues"]).to eq([])
    expect(parse_body["freshness"]).to include("synchronized" => false, "synced_at" => nil, "stale" => false)
  end

  it "closes and delegates GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    fake_issue(repository: repository, number: 12)
    fake_issue(repository: repository, number: 13)
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    expect(client).to receive(:close_issue).with("acme/widgets", 12)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 13, "syrus")
    allow(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    allow(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/close", params: { issue_number: 12, folder: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #12 closed.")
    expect(GithubIssue.where(repository: repository).find_by!(number: 12).state).to eq("closed")

    post "/api/v1/app/repositories/#{repository.id}/issues/delegate", params: { issue_number: 13, folder: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #13 delegated to Syrus.")
    expect(GithubIssue.where(repository: repository).find_by!(number: 13)).to be_delegated("syrus")
  end

  it "forbids read-tier members from mutating GitHub issues" do
    owner = user
    reader = Factories.user
    repository = Factories.repository(user: owner, owner: "acme", name: "widgets", trigger_label: "syrus")
    repository.repository_memberships.create!(user: reader, role: "read")
    sign_in_as(reader)
    expect(GithubClient).not_to receive(:for)

    [
      [ :post, "/api/v1/app/repositories/#{repository.id}/issues/close", { issue_number: 12 } ],
      [ :post, "/api/v1/app/repositories/#{repository.id}/issues/delegate", { issue_number: 13 } ],
      [ :post, "/api/v1/app/repositories/#{repository.id}/issues/bulk", { issue_numbers: %w[4 8], bulk_action: "delegate" } ]
    ].each do |method, path, params|
      public_send(method, path, params: params)

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "message")).to include("write access")
    end
  end


  it "bulk closes and delegates selected GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    fake_issue(repository: repository, number: 4)
    fake_issue(repository: repository, number: 8)
    client = instance_double(GithubClient)
    stub_no_linked_pull_requests(client)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 4, "syrus")
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 8, "syrus")
    expect(client).to receive(:close_issue).with("acme/widgets", 4)
    allow(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    allow(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 8],
      bulk_action: "delegate",
      folder: "open"
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("2 issues delegated to Syrus.")

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 4 invalid],
      bulk_action: "close",
      folder: "open"
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("1 issue closed.")
  end

  it "keeps successful bulk delegates cache-consistent when a later GitHub mutation fails" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    fake_issue(repository: repository, number: 4)
    fake_issue(repository: repository, number: 8)
    client = instance_double(GithubClient)
    failure = Octokit::Error.new(status: 502, body: "unavailable")
    expect(client).to receive(:add_label_to_issue).with(repository.slug, 4, "syrus")
    expect(client).to receive(:add_label_to_issue).with(repository.slug, 8, "syrus").and_raise(failure)
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: { issue_numbers: %w[4 8], bulk_action: "delegate" }

    expect(response).to have_http_status(:bad_gateway)
    expect(GithubIssue.find_by!(repository: repository, number: 4)).to be_delegated("syrus")
    expect(GithubIssue.find_by!(repository: repository, number: 8)).not_to be_delegated("syrus")
  end

  it "keeps successful bulk closes cache-consistent when a later GitHub mutation fails" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    fake_issue(repository: repository, number: 4)
    fake_issue(repository: repository, number: 8)
    client = instance_double(GithubClient)
    failure = Octokit::Error.new(status: 502, body: "unavailable")
    expect(client).to receive(:close_issue).with(repository.slug, 4)
    expect(client).to receive(:close_issue).with(repository.slug, 8).and_raise(failure)
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: { issue_numbers: %w[4 8], bulk_action: "close" }

    expect(response).to have_http_status(:bad_gateway)
    expect(GithubIssue.find_by!(repository: repository, number: 4).state).to eq("closed")
    expect(GithubIssue.find_by!(repository: repository, number: 8).state).to eq("open")
  end


  it "rejects bulk GitHub issue commands without selected issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: { bulk_action: "delegate" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Select")
  end
end
