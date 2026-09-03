require "rails_helper"

RSpec.describe "API: repository GitHub issues", :ci_only, type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
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


  it "does not serve GitHub Issues in simple mode" do
    sign_in_as(user)
    AppSetting.current.update!(mode: "simple", mode_configured_at: Time.current)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    get "/api/v1/app/repositories/#{repository.id}/issues"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "message")).to eq("GitHub issues are not available in simple mode.")
  end


  it "returns repository GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    issue = fake_issue(number: 7, title: "Fix the forum", labels: [ "syrus", "bug" ], body: "Line one\nLine two")
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([ issue ])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { state: "closed" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["state"]).to eq("closed")
    expect(body["issue_count"]).to eq(1)
    expect(body["issues"]).to contain_exactly(include(
      "number" => 7,
      "title" => "Fix the forum",
      "body_excerpt" => "Line one Line two",
      "user_login" => "alice",
      "delegated" => true,
      "labels" => include({ "name" => "bug", "color" => "0075ca" })
    ))
    expect(body.dig("paths", "app_delegate_issue_path")).to eq("/api/v1/app/repositories/#{repository.id}/issues/delegate")
    expect(body.dig("state_paths", "open")).to eq(repository_path(repository, tab: "github_issues", state: "open"))
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


  it "comments on a GitHub issue" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    client = instance_double(GithubClient)
    expect(client).to receive(:add_issue_comment).with("acme/widgets", 7, "Looks good", on_behalf_of: user)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/comment", params: {
      issue_number: 7,
      comment_body: "Looks good",
      state: "open"
    }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Comment added to #7.")
  end


  it "rejects blank GitHub issue comments" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    post "/api/v1/app/repositories/#{repository.id}/issues/comment", params: {
      issue_number: 7,
      comment_body: " "
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("blank")
  end


  it "closes and delegates GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    client = instance_double(GithubClient)
    expect(client).to receive(:close_issue).with("acme/widgets", 12)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 13, "syrus")
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/close", params: { issue_number: 12, state: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #12 closed.")

    post "/api/v1/app/repositories/#{repository.id}/issues/delegate", params: { issue_number: 13, state: "open" }
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
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 8],
      bulk_action: "delegate",
      state: "open"
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("2 issues delegated to Syrus.")

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 4 invalid],
      bulk_action: "close",
      state: "open"
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
