require "rails_helper"

RSpec.describe Steps::CoveragePrComment do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) do
    Step.create!(workflow: workflow, kind: "coverage_pr_comment", position: 99)
  end
  let(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind,
                      state: "running", iteration: step.iteration)
  end
  let(:handler) { described_class.new(run) }

  let(:fake_client) { instance_double(GithubClient) }
  let(:pr_comment_body) do
    "#{CoverageReport::PrCommentFormatter::MARKER}\n## Test Coverage Report\n\n| Metric | Value |"
  end

  before do
    job.user.update!(github_handle: "operator")
    allow(GithubClient).to receive(:for_authorship).and_return(fake_client)
  end

  context "when coverage artifact has no pr_comment_body" do
    it "skips without calling the GitHub API" do
      expect(fake_client).not_to receive(:add_issue_comment)
      expect(fake_client).not_to receive(:update_issue_comment)
      handler.call
    end

    it "skips gracefully when coverage artifact is nil" do
      # No artifact set at all
      expect { handler.call }.not_to raise_error
    end

    it "skips gracefully when coverage_unavailable is true" do
      workflow.set_artifact!("coverage", { "coverage_unavailable" => true })
      expect(fake_client).not_to receive(:add_issue_comment)
      handler.call
    end
  end

  context "when pr_comment_body is set but no PR exists" do
    before do
      workflow.set_artifact!("coverage", { "pr_comment_body" => pr_comment_body })
    end

    it "skips when job has no pr_number" do
      expect(fake_client).not_to receive(:add_issue_comment)
      handler.call
    end
  end

  context "when pr_comment_body is set and PR exists" do
    before do
      job.update!(pr_number: 42)
      workflow.set_artifact!("coverage", { "pr_comment_body" => pr_comment_body })
    end

    context "when no existing coverage comment is found" do
      before do
        allow(fake_client).to receive(:pr_issue_comments).and_return([])
        allow(fake_client).to receive(:add_issue_comment)
      end

      it "creates a new comment" do
        expect(fake_client).to receive(:add_issue_comment).with(
          job.repository.slug, 42, pr_comment_body
        )
        handler.call
      end

      it "queries PR comments before posting" do
        expect(fake_client).to receive(:pr_issue_comments).with(
          job.repository.slug, 42
        ).and_return([])
        allow(fake_client).to receive(:add_issue_comment)
        handler.call
      end

      it "uses the Job authorship credential when an App installation is active" do
        AppSetting.current.update!(github_app_id: 123, github_app_slug: "syrus-local")
        job.user.update!(github_token: "ghp_operator_token")
        installation = Factories.installation(
          user: job.user,
          cached_token: "installation-token",
          cached_token_expires_at: 1.hour.from_now
        )
        job.repository.update!(installation: installation)
        job.update!(credential_mode: "pat")
        comments_url = "https://api.github.com/repos/#{job.repository.slug}/issues/42/comments"
        list_request = stub_request(:get, comments_url)
          .with(query: hash_including({}), headers: { "Authorization" => "token ghp_operator_token" })
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)
        post_request = stub_request(:post, comments_url)
          .with(headers: { "Authorization" => "token ghp_operator_token" })
          .to_return(status: 201, headers: { "Content-Type" => "application/json" }, body: { id: 99 }.to_json)

        expect(GithubClient).to receive(:for_authorship).and_call_original
        handler.call

        expect(list_request).to have_been_requested
        expect(post_request).to have_been_requested
      end
    end

    context "when an existing coverage comment is found" do
      let(:existing_comment) do
        double("comment", id: 777,
               user: double(login: "operator"),
               body: "#{CoverageReport::PrCommentFormatter::MARKER}\nold content")
      end

      before do
        allow(fake_client).to receive(:pr_issue_comments).and_return([ existing_comment ])
        allow(fake_client).to receive(:update_issue_comment)
      end

      it "updates the existing comment instead of creating a new one" do
        expect(fake_client).to receive(:update_issue_comment).with(
          job.repository.slug, 777, pr_comment_body
        )
        expect(fake_client).not_to receive(:add_issue_comment)
        handler.call
      end

      it "ignores a foreign comment containing the marker" do
        foreign_comment = double("comment", id: 666, user: double(login: "reviewer"),
                                 body: "#{CoverageReport::PrCommentFormatter::MARKER}\nquoted content")
        allow(fake_client).to receive(:pr_issue_comments).and_return([ foreign_comment, existing_comment ])

        expect(fake_client).to receive(:update_issue_comment).with(
          job.repository.slug, 777, pr_comment_body
        )
        handler.call
      end

      it "posts a new comment when updating the owned comment fails" do
        allow(fake_client).to receive(:update_issue_comment).and_raise(RuntimeError, "forbidden")

        expect(fake_client).to receive(:add_issue_comment).with(
          job.repository.slug, 42, pr_comment_body
        )
        handler.call
      end
    end

    context "when pr_issue_comments raises an error" do
      before do
        allow(fake_client).to receive(:pr_issue_comments).and_raise(
          RuntimeError, "GitHub API unavailable"
        )
        allow(fake_client).to receive(:add_issue_comment)
      end

      it "falls back to posting a new comment" do
        expect(fake_client).to receive(:add_issue_comment).with(
          job.repository.slug, 42, pr_comment_body
        )
        handler.call
      end
    end
  end
end
