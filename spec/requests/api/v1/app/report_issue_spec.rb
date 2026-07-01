require "rails_helper"

RSpec.describe "API: /api/v1/app/report_issue", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "creates a GitHub issue in the configured report repository" do
    user = Factories.user(github_token: "ghp_report")
    AppSetting.current.update!(report_issue_repo_slug: "acme/syrus")
    sign_in_as(user)

    stub = stub_request(:post, "https://api.github.com/repos/acme/syrus/issues")
      .with(
        headers: { "Authorization" => "token ghp_report" },
        body: hash_including(
          "title" => "Chat report",
          "body" => "Something broke.",
          "labels" => []
        )
      )
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { number: 123, html_url: "https://github.com/acme/syrus/issues/123" }.to_json
      )

    post "/api/v1/app/report_issue", params: { title: "Chat report", body: "Something broke." }

    expect(response).to have_http_status(:created)
    expect(parse_body).to eq("issue_url" => "https://github.com/acme/syrus/issues/123")
    expect(stub).to have_been_requested
  end

  it "returns a clear error when the user has no GitHub token" do
    user = Factories.user(github_token: nil)
    sign_in_as(user)

    post "/api/v1/app/report_issue", params: { title: "Chat report", body: "Something broke." }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("github_token_required")
    expect(parse_body.dig("error", "message")).to eq("Connect a GitHub token before filing a report.")
  end
end
