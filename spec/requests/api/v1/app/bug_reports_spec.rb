require "rails_helper"

RSpec.describe "API: /api/v1/app/bug_reports", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def upload_png(content: "\x89PNG\r\n\x1A\nscreenshot".b)
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      "image/png",
      original_filename: "capture.png"
    )
  end

  it "401s with a JSON error when signed out" do
    post "/api/v1/app/bug_reports", params: { title: "Unauthed" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  context "when the system-wide bug-report repository exists (condition A)" do
    before do
      AppSetting.current.update!(report_issue_repo_slug: "operator/syrus")
    end

    it "creates a direct Job for the configured Syrus bug-report repository" do
      repository = Factories.repository(user: user, owner: "operator", name: "syrus")
      sign_in_as(user)

      expect {
        post "/api/v1/app/bug_reports", params: {
          title: "Home#index bug",
          description: "The dashboard fell over.",
          screenshot: upload_png
        }
      }.to change(Job, :count).by(1)
        .and change(Document, :count).by(1)
        .and change(Workflow, :count).by(1)
        .and change(Run, :count).by(1)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(parse_body).to include("message" => "Bug report queued.", "job_id" => job.id)
      expect(job).to have_attributes(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Home#index bug",
        issue_body: "Home#index bug\n\nThe dashboard fell over."
      )
      expect(job.job_attachments.last.filename).to eq("capture.png")
    end

    it "attaches additional files alongside the screenshot to the direct Job" do
      Factories.repository(user: user, owner: "operator", name: "syrus")
      sign_in_as(user)

      log_file = Rack::Test::UploadedFile.new(StringIO.new("log content"), "text/plain", original_filename: "app.log")
      pdf_file = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4 dummy"), "application/pdf", original_filename: "report.pdf")

      expect {
        post "/api/v1/app/bug_reports", params: {
          title: "Multi-file bug",
          description: "With extra files.",
          screenshot: upload_png,
          attachments: [ log_file, pdf_file ]
        }
      }.to change(Job, :count).by(1)
        .and change(Document, :count).by(3)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(job.job_attachments.map(&:filename)).to include("capture.png", "app.log", "report.pdf")
    end

    it "returns a validation error when more than MAX_ATTACHMENTS_PER_JOB files are sent" do
      Factories.repository(user: user, owner: "operator", name: "syrus")
      sign_in_as(user)

      extra_files = (1..Document::MAX_ATTACHMENTS_PER_JOB).map do |i|
        Rack::Test::UploadedFile.new(StringIO.new("content#{i}"), "text/plain", original_filename: "file#{i}.txt")
      end

      expect {
        post "/api/v1/app/bug_reports", params: {
          title: "Too many files",
          description: "Exceeds the limit.",
          screenshot: upload_png,
          attachments: extra_files
        }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "allows a user who does not own the bug-report repository to file a report" do
      owner_user = Factories.user
      Factories.repository(user: owner_user, owner: "operator", name: "syrus")
      non_owner = Factories.user
      sign_in_as(non_owner)

      expect {
        post "/api/v1/app/bug_reports", params: {
          title: "Bug from non-owner",
          description: "Filed by someone else."
        }
      }.to change(Job, :count).by(1)
        .and change(Workflow, :count).by(1)
        .and change(Run, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(Job.last).to have_attributes(user: non_owner, kind: "direct", issue_title: "Bug from non-owner")
    end
  end

  context "when the user has a fork of the upstream repo (condition B)" do
    before do
      AppSetting.current.update!(report_issue_repo_slug: "upstream-org/syrus")
    end

    it "creates a direct Job against the user's fork" do
      fork = Factories.repository(
        user: user,
        owner: "my-fork-org",
        name: "syrus",
        upstream_owner: "upstream-org",
        upstream_name: "syrus"
      )
      sign_in_as(user)

      expect {
        post "/api/v1/app/bug_reports", params: { title: "Fork bug", description: "Found in my fork." }
      }.to change(Job, :count).by(1)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(parse_body).to include("job_id" => job.id)
      expect(job).to have_attributes(repository: fork, kind: "direct", issue_title: "Fork bug")
    end
  end

  context "when neither condition is met (GitHub issue path)" do
    it "returns github_token_required when the user has no GitHub token" do
      sign_in_as(user)

      expect {
        post "/api/v1/app/bug_reports", params: { title: "Missing repo" }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("github_token_required")
      expect(parse_body.dig("error", "message")).to eq("Connect a GitHub token before filing a report.")
    end

    it "files a GitHub issue and returns issue_url when the user has a GitHub token" do
      AppSetting.current.update!(report_issue_repo_slug: "upstream-org/syrus")
      user_with_token = Factories.user(github_token: "ghp_bugtest")
      sign_in_as(user_with_token)

      stub = stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
        .with(
          headers: { "Authorization" => "token ghp_bugtest" },
          body: hash_including("title" => "Upstream bug", "body" => "Something broke upstream.", "labels" => [])
        )
        .to_return(
          status: 201,
          headers: { "Content-Type" => "application/json" },
          body: { number: 42, html_url: "https://github.com/upstream-org/syrus/issues/42" }.to_json
        )

      expect {
        post "/api/v1/app/bug_reports", params: {
          title: "Upstream bug",
          description: "Something broke upstream."
        }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:created)
      expect(parse_body).to eq("message" => "Bug report filed.", "issue_url" => "https://github.com/upstream-org/syrus/issues/42")
      expect(stub).to have_been_requested
    end

    context "with screenshot attachment" do
      let(:user_with_token) { Factories.user(github_token: "ghp_bugtest") }
      let(:asset_url) { "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid/capture.png" }

      before do
        AppSetting.current.update!(report_issue_repo_slug: "upstream-org/syrus")
        sign_in_as(user_with_token)
      end

      def stub_github_issue(expected_body)
        stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
          .with(body: hash_including("body" => expected_body))
          .to_return(
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: { number: 55, html_url: "https://github.com/upstream-org/syrus/issues/55" }.to_json
          )
      end

      it "uploads the screenshot and embeds it as a markdown image in the issue body" do
        allow_any_instance_of(GithubClient).to receive(:upload_issue_asset).and_return(asset_url)
        issue_stub = stub_github_issue("Bug here.\n\n![Screenshot](#{asset_url})")

        post "/api/v1/app/bug_reports", params: {
          title: "Screenshot bug",
          description: "Bug here.",
          screenshot: upload_png
        }

        expect(response).to have_http_status(:created)
        expect(issue_stub).to have_been_requested
      end

      it "still files the issue with a fallback note when the screenshot upload fails" do
        allow_any_instance_of(GithubClient).to receive(:upload_issue_asset).and_return(nil)
        issue_stub = stub_github_issue(
          "Bug here.\n\n_Attachment could not be uploaded automatically. Please attach it manually._"
        )

        post "/api/v1/app/bug_reports", params: {
          title: "Screenshot bug",
          description: "Bug here.",
          screenshot: upload_png
        }

        expect(response).to have_http_status(:created)
        expect(issue_stub).to have_been_requested
      end

      it "embeds additional attachments as a markdown list" do
        extra_url = "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid2/log.txt"
        allow_any_instance_of(GithubClient).to receive(:upload_issue_asset).and_return(asset_url, extra_url)
        issue_stub = stub_github_issue("Details.\n\n![Screenshot](#{asset_url})\n\n- [log.txt](#{extra_url})")

        log_file = Rack::Test::UploadedFile.new(StringIO.new("log content"), "text/plain", original_filename: "log.txt")
        post "/api/v1/app/bug_reports", params: {
          title: "Multi attachment",
          description: "Details.",
          screenshot: upload_png,
          attachments: [ log_file ]
        }

        expect(response).to have_http_status(:created)
        expect(issue_stub).to have_been_requested
      end
    end
  end
end
