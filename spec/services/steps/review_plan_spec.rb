require "rails_helper"
require "tmpdir"

RSpec.describe Steps::ReviewPlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job) }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let!(:implement_run) do
    Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
  end
  let(:review_plan_step) { workflow.steps.find_by!(kind: "review_plan") }
  let(:run) do
    Run.create!(job: job, step: review_plan_step, trigger_kind: "initial").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-review-plan") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: true, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  def write_syrus_yml(content)
    @ws_path.join(".syrus.yml").write(content)
  end

  context "when review_plan is not configured" do
    it "no-ops without invoking the agent when .syrus.yml is absent" do
      expect(handler).not_to receive(:run_agent)

      handler.call
    end

    it "no-ops when .syrus.yml exists but review_plan is false" do
      write_syrus_yml("review_plan: false\n")

      expect(handler).not_to receive(:run_agent)
      handler.call
    end

    it "no-ops when .syrus.yml fails to parse" do
      write_syrus_yml("review_plan: [\n")

      expect(handler).not_to receive(:run_agent)
      expect { handler.call }.not_to raise_error
    end
  end

  context "when review_plan is enabled" do
    before { write_syrus_yml("review_plan: true\n") }

    it "skips the agent call when the artifact already exists" do
      workflow.set_artifact!("review_plan", { "items" => [], "summary" => nil })

      expect(handler).not_to receive(:run_agent)
      handler.call
    end

    it "sets the review-plan prompt and invokes the agent with a short turn budget" do
      expect(handler).to receive(:run_agent) do |prompt:, max_turns:, required_mcp_tools:|
        expect(prompt).to include("submit_review_plan")
        expect(max_turns).to eq(described_class::REVIEW_PLAN_TURN_BUDGET)
        expect(required_mcp_tools).to eq(%w[submit_review_plan])
        workflow.set_artifact!("review_plan", { "items" => [], "summary" => nil })
      end

      handler.call

      expect(run.reload.prompt).to include("submit_review_plan")
    end

    it "posts a PR comment when the agent submits review items" do
      job.update!(pr_number: 42)
      fake_client = instance_double(GithubClient, pr_issue_comments: [])
      allow(GithubClient).to receive(:for).and_return(fake_client)
      allow(fake_client).to receive(:add_issue_comment)

      allow(handler).to receive(:run_agent) do
        workflow.set_artifact!("review_plan", {
          "items" => [ { "file" => "app/models/user.rb", "line" => 10, "note" => "Tricky retry logic." } ],
          "summary" => nil
        })
      end

      handler.call

      expect(fake_client).to have_received(:add_issue_comment).with(
        repository.slug, 42, a_string_including("app/models/user.rb:10", "Tricky retry logic.")
      )
    end

    it "updates an existing review-plan comment instead of creating a new one" do
      job.update!(pr_number: 42)
      existing_comment = double("comment", id: 777, body: "#{ReviewPlanFormatter::MARKER}\nold content")
      fake_client = instance_double(GithubClient, pr_issue_comments: [ existing_comment ])
      allow(GithubClient).to receive(:for).and_return(fake_client)
      allow(fake_client).to receive(:update_issue_comment)

      allow(handler).to receive(:run_agent) do
        workflow.set_artifact!("review_plan", {
          "items" => [ { "file" => "app/models/user.rb", "line" => 10, "note" => "Tricky retry logic." } ],
          "summary" => nil
        })
      end

      handler.call

      expect(fake_client).to have_received(:update_issue_comment).with(repository.slug, 777, anything)
    end

    it "does not post a comment when the agent submits no items" do
      job.update!(pr_number: 42)
      fake_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).and_return(fake_client)

      allow(handler).to receive(:run_agent) do
        workflow.set_artifact!("review_plan", { "items" => [], "summary" => nil })
      end

      expect(fake_client).not_to receive(:pr_issue_comments)
      expect(fake_client).not_to receive(:add_issue_comment)
      handler.call
    end

    it "does not post a comment when the job has no PR number" do
      fake_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).and_return(fake_client)

      allow(handler).to receive(:run_agent) do
        workflow.set_artifact!("review_plan", {
          "items" => [ { "file" => "app.rb", "line" => nil, "note" => "Check this." } ],
          "summary" => nil
        })
      end

      expect(fake_client).not_to receive(:add_issue_comment)
      handler.call
    end

    it "swallows StepFailed and does not raise when the agent never calls submit_review_plan" do
      allow(handler).to receive(:run_agent)

      expect { handler.call }.not_to raise_error
      expect(workflow.reload.artifact("review_plan")).to be_nil
    end

    it "swallows StepFailed and does not raise when run_agent errors" do
      allow(handler).to receive(:run_agent).and_raise(Steps::Base::StepFailed, "agent reported error")

      expect { handler.call }.not_to raise_error
    end

    it "swallows a GitHub API failure while posting the comment" do
      job.update!(pr_number: 42)
      fake_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).and_return(fake_client)
      allow(fake_client).to receive(:pr_issue_comments).and_raise(RuntimeError, "GitHub API unavailable")
      allow(fake_client).to receive(:add_issue_comment)

      allow(handler).to receive(:run_agent) do
        workflow.set_artifact!("review_plan", {
          "items" => [ { "file" => "app.rb", "line" => nil, "note" => "Check this." } ],
          "summary" => nil
        })
      end

      expect { handler.call }.not_to raise_error
      expect(fake_client).to have_received(:add_issue_comment)
    end

    it "resumes from the succeeded implement session" do
      ProviderSession.create!(resumable: implement_run, session_id: "implement-thread", transcript_jsonl: "{}\n")

      handler.singleton_class.send(:public, :parent_session_id)

      expect(handler.parent_session_id).to eq("implement-thread")
    end
  end
end
