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

  def fake_issue(number:, title: "Fix something", state: "open", labels: [], body: nil)
    double(
      "issue",
      number: number,
      title: title,
      state: state,
      html_url: "https://github.com/acme/widgets/issues/#{number}",
      body: body,
      created_at: 1.day.ago,
      user: double("user", login: "alice"),
      labels: labels.map { |name| double("label", name: name, color: "0075ca") }
    )
  end


  it "returns repository GitHub issues for the requested smart folder" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    open_issue = fake_issue(number: 5, title: "Open one", labels: [])
    closed_issue = fake_issue(number: 7, title: "Fix the forum", state: "closed", labels: [ "syrus", "bug" ], body: "Line one\nLine two")
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ open_issue ])
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([ closed_issue ])
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
    inbox_issue = fake_issue(number: 1, title: "Needs triage", labels: [])
    delegated_issue = fake_issue(number: 2, title: "Already delegated", labels: [ "syrus" ])
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ inbox_issue, delegated_issue ])
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { folder: "inbox" }

    body = parse_body
    expect(body["issues"].map { |issue| issue["number"] }).to eq([ 1 ])
    expect(body["folder_counts"]).to eq({ "inbox" => 1, "delegated" => 1, "open" => 2, "closed" => 0 })
  end


  it "filters issues by a search query within the active folder without changing other folder counts" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    matching = fake_issue(number: 1, title: "Fix the forum", labels: [])
    other = fake_issue(number: 2, title: "Unrelated", labels: [])
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([ matching, other ])
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
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
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues"

    fields = parse_body["filter_schema"].index_by { |field| field["field"] }
    expect(fields.fetch("query")).to include("free_text_search" => true, "bucket" => "string")
  end


  it "falls back to the closed folder for legacy state=closed links" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { state: "closed" }

    expect(parse_body["folder"]).to eq("closed")
  end


  it "returns an issues payload error when GitHub credentials are missing" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    allow(GithubClient).to receive(:for).and_raise(ArgumentError)

    get "/api/v1/app/repositories/#{repository.id}/issues"

    expect(response).to have_http_status(:ok)
    expect(parse_body["issues"]).to eq([])
    expect(parse_body["error_message"]).to include("No GitHub token configured")
  end


  it "closes and delegates GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    client = instance_double(GithubClient)
    expect(client).to receive(:close_issue).with("acme/widgets", 12)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 13, "syrus")
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "closed").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/close", params: { issue_number: 12, folder: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #12 closed.")

    post "/api/v1/app/repositories/#{repository.id}/issues/delegate", params: { issue_number: 13, folder: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #13 delegated to Syrus.")
  end


  it "bulk closes and delegates selected GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    client = instance_double(GithubClient)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 4, "syrus")
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 8, "syrus")
    expect(client).to receive(:close_issue).with("acme/widgets", 4)
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "closed").and_return([])
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


  it "rejects bulk GitHub issue commands without selected issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: { bulk_action: "delegate" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Select")
  end
end
