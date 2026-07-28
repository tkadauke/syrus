require "rails_helper"

RSpec.describe BugReports::GithubIssueCreator do
  let(:user) { Factories.user(github_token: "ghp_pat_token") }

  before do
    AppSetting.current.update!(report_issue_repo_slug: "upstream-org/syrus")
  end

  def screenshot_io
    Rack::Test::UploadedFile.new(
      StringIO.new("\x89PNG\r\nfakedata"),
      "image/png",
      original_filename: "shot.png"
    )
  end

  def fake_issue_url
    "https://github.com/upstream-org/syrus/issues/77"
  end

  # Stub upload_issue_asset on all GithubClient instances created during the
  # example. Returns the given URL (or nil to simulate upload failure).
  def stub_upload(url)
    allow_any_instance_of(GithubClient).to receive(:upload_issue_asset).and_return(url)
  end

  def stub_issue_create(body_matcher: anything)
    stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
      .with(body: body_matcher)
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { number: 77, html_url: fake_issue_url }.to_json
      )
  end

  describe "upload client selection" do
    let(:issue_client) { instance_spy(GithubClient) }
    let(:fake_issue) { double("issue", html_url: fake_issue_url) }

    before do
      allow(GithubClient).to receive(:for_user).with(user).and_return(issue_client)
      allow(issue_client).to receive(:create_issue).and_return(fake_issue)
    end

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
      let(:upload_client) { instance_double(GithubClient) }

      before do
        allow(GithubClient).to receive(:for).with(repository: target_repo, user: user).and_return(upload_client)
      end

      it "uses the installation-backed client for asset uploads" do
        allow(upload_client).to receive(:upload_issue_asset).and_return(
          "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid/shot.png"
        )

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(upload_client).to have_received(:upload_issue_asset)
        expect(issue_client).not_to have_received(:upload_issue_asset)
      end

      it "still uses the PAT-backed client for issue creation" do
        allow(upload_client).to receive(:upload_issue_asset).and_return(nil)

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(issue_client).to have_received(:create_issue)
      end
    end

    context "when no Repository record exists for the report slug" do
      it "uses the PAT-backed client for asset uploads" do
        allow(issue_client).to receive(:upload_issue_asset).and_return(
          "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid/shot.png"
        )

        BugReports::GithubIssueCreator.new(user: user).call(
          title: "T", description: "D", screenshot: screenshot_io
        )

        expect(issue_client).to have_received(:upload_issue_asset)
      end
    end
  end

  describe "#call" do
    it "returns github_token_required when the user has no GitHub token" do
      tokenless = Factories.user
      result = BugReports::GithubIssueCreator.new(user: tokenless).call(
        title: "T", description: "D"
      )
      expect(result.error_code).to eq("github_token_required")
      expect(result.issue_url).to be_nil
    end

    it "embeds the screenshot as a markdown image when upload succeeds" do
      url = "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid/shot.png"
      stub_upload(url)
      issue_stub = stub_issue_create(
        body_matcher: hash_including("body" => "Details.\n\n![Screenshot](#{url})")
      )

      BugReports::GithubIssueCreator.new(user: user).call(
        title: "T", description: "Details.", screenshot: screenshot_io
      )

      expect(issue_stub).to have_been_requested
    end

    it "uses a fallback note in the body when screenshot upload fails" do
      stub_upload(nil)
      issue_stub = stub_issue_create(
        body_matcher: hash_including(
          "body" => "Details.\n\n_Attachment could not be uploaded automatically. Please attach it manually._"
        )
      )

      BugReports::GithubIssueCreator.new(user: user).call(
        title: "T", description: "Details.", screenshot: screenshot_io
      )

      expect(issue_stub).to have_been_requested
    end

    it "embeds additional attachments as a markdown list" do
      shot_url = "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid1/shot.png"
      log_url  = "https://raw.githubusercontent.com/upstream-org/syrus/bug-report-media/bug-report-attachments/uuid2/log.txt"
      allow_any_instance_of(GithubClient).to receive(:upload_issue_asset).and_return(shot_url, log_url)
      issue_stub = stub_issue_create(
        body_matcher: hash_including(
          "body" => "Details.\n\n![Screenshot](#{shot_url})\n\n- [log.txt](#{log_url})"
        )
      )

      log_file = Rack::Test::UploadedFile.new(StringIO.new("log content"), "text/plain", original_filename: "log.txt")
      BugReports::GithubIssueCreator.new(user: user).call(
        title: "T", description: "Details.", screenshot: screenshot_io, attachments: [ log_file ]
      )

      expect(issue_stub).to have_been_requested
    end

    it "returns github_error when Octokit raises on issue creation" do
      stub_upload(nil)
      stub_request(:post, "https://api.github.com/repos/upstream-org/syrus/issues")
        .to_return(status: 422, headers: { "Content-Type" => "application/json" },
                   body: { message: "Validation Failed" }.to_json)

      result = BugReports::GithubIssueCreator.new(user: user).call(title: "T", description: "D")
      expect(result.error_code).to eq("github_error")
      expect(result.issue_url).to be_nil
    end
  end
end
