require "rails_helper"

RSpec.describe BugReports::GithubIssueCreator do
  let(:user) { Factories.user(github_token: "ghp_pat_token") }
  let(:policy_url) { "https://github.com/upstream-org/syrus/upload/policies/assets" }
  let(:s3_url) { "https://objects.githubusercontent.com/github-production-repository/uploads/shot" }
  let(:asset_href) { "https://github.com/user-attachments/assets/abc-uuid" }

  before do
    AppSetting.current.update!(report_issue_repo_slug: "upstream-org/syrus")
  end

  def stub_issue_create(body_matcher: anything)
    stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
      .with(body: body_matcher)
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { number: 77, html_url: "https://github.com/upstream-org/syrus/issues/77" }.to_json
      )
  end

  def screenshot_io
    Rack::Test::UploadedFile.new(
      StringIO.new("\x89PNG\r\nfakedata"),
      "image/png",
      original_filename: "shot.png"
    )
  end

  describe "upload client selection" do
    context "when a Repository record exists for the report slug with an active installation" do
      let!(:target_repo) do
        Factories.repository(user: Factories.user, owner: "upstream-org", name: "syrus")
      end
      let!(:installation) do
        inst = Factories.installation(
          user: target_repo.user,
          cached_token: "ghs_install_token",
          cached_token_expires_at: 1.hour.from_now
        )
        target_repo.update!(installation: inst)
        inst
      end

      it "sends an installation Bearer token to the asset upload endpoint" do
        policy_stub = stub_request(:post, policy_url)
          .with(headers: { "Authorization" => "Bearer ghs_install_token" })
          .to_return(
            status: 201, headers: { "Content-Type" => "application/json" },
            body: { upload_url: s3_url, form: {}, asset: { href: asset_href } }.to_json
          )
        stub_request(:post, s3_url).to_return(status: 204, body: "")
        stub_issue_create

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(policy_stub).to have_been_requested
      end

      it "still uses PAT for the issue creation request" do
        stub_request(:post, policy_url)
          .to_return(
            status: 201, headers: { "Content-Type" => "application/json" },
            body: { upload_url: s3_url, form: {}, asset: { href: asset_href } }.to_json
          )
        stub_request(:post, s3_url).to_return(status: 204, body: "")
        issue_stub = stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
          .with(headers: { "Authorization" => "token ghp_pat_token" })
          .to_return(
            status: 201, headers: { "Content-Type" => "application/json" },
            body: { number: 77, html_url: "https://github.com/upstream-org/syrus/issues/77" }.to_json
          )

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(issue_stub).to have_been_requested
      end
    end

    context "when no Repository record exists for the report slug" do
      it "falls back to PAT Bearer token for the asset upload endpoint" do
        policy_stub = stub_request(:post, policy_url)
          .with(headers: { "Authorization" => "Bearer ghp_pat_token" })
          .to_return(
            status: 201, headers: { "Content-Type" => "application/json" },
            body: { upload_url: s3_url, form: {}, asset: { href: asset_href } }.to_json
          )
        stub_request(:post, s3_url).to_return(status: 204, body: "")
        stub_issue_create

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(policy_stub).to have_been_requested
      end
    end
  end
end
