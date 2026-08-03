require "rails_helper"

RSpec.describe Workflows::ExternalPrIngest do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user) }

  def same_repo_job
    Job.create!(
      user: user, repository: repository,
      kind: "external_pr", state: "implemented",
      external_pr_number: 42, external_pr_author: "alice",
      external_pr_fork: false, branch_name: "feature/cool-thing",
      issue_title: "Add cool thing"
    ).tap { |j| j.update_columns(state: "running") }
  end

  def fork_job
    Job.create!(
      user: user, repository: repository,
      kind: "external_pr", state: "implemented",
      external_pr_number: 43, external_pr_author: "bob",
      external_pr_fork: true, branch_name: "feature/fork-thing",
      issue_title: "Fork contribution"
    ).tap { |j| j.update_columns(state: "running") }
  end

  describe ".steps_for" do
    context "for a same-repo PR" do
      it "returns prepare → retry_until(landing_fix, grader_fanout + grader_collect) → push" do
        chain = described_class.steps_for(same_repo_job)
        kinds = chain.flat_map { |node|
          node.is_a?(String) ? node : "retry_until"
        }
        expect(kinds).to include("prepare", "retry_until", "push")
        expect(kinds).not_to include("grader_fanout")
      end

      it "includes grader steps inside the retry_until node" do
        chain = described_class.steps_for(same_repo_job)
        retry_node = chain.find { |node| node.is_a?(Workflows::RetryUntil) }
        expect(retry_node).to be_present
        expect(retry_node.check_steps).to include("grader_fanout", "grader_collect")
        expect(retry_node.repair_steps).to include("landing_fix")
      end
    end

    context "for a fork PR" do
      it "returns prepare → grader_fanout → grader_collect" do
        chain = described_class.steps_for(fork_job)
        expect(chain).to eq(%w[ prepare grader_fanout grader_collect ])
      end
    end
  end

  describe ".after_fail" do
    let(:client_double) { instance_double(GithubClient) }

    before do
      allow(GithubClient).to receive(:for).and_return(client_double)
      allow(client_double).to receive(:create_pr_review)
    end

    context "when the job is a fork PR" do
      let(:job) { fork_job }
      let(:workflow) { Workflow.create!(job: job, trigger_kind: "external_pr_ingest") }

      before do
        step = Step.create!(workflow: workflow, kind: "grader", position: 0, iteration: 1, state: "failed",
                            details: { "name" => "rspec", "required" => true })
        Step.create!(workflow: workflow, kind: "grader", position: 1, iteration: 1, state: "succeeded",
                     details: { "name" => "eslint", "required" => false })
      end

      it "reverts the job to :implemented" do
        described_class.after_fail(workflow)
        expect(job.reload).to be_implemented
      end

      it "posts a REQUEST_CHANGES review on the PR" do
        described_class.after_fail(workflow)
        expect(client_double).to have_received(:create_pr_review).with(
          repository.slug,
          job.external_pr_number,
          event: "REQUEST_CHANGES",
          body: a_string_including("rspec")
        )
      end

      it "only mentions required failed graders in the review body" do
        described_class.after_fail(workflow)
        expect(client_double).to have_received(:create_pr_review).with(
          anything, anything,
          event: "REQUEST_CHANGES",
          body: satisfy { |b| !b.include?("eslint") }
        )
      end

      it "skips the review comment when no required graders failed" do
        workflow.steps.where(kind: "grader").update_all(state: "succeeded")
        described_class.after_fail(workflow)
        expect(client_double).not_to have_received(:create_pr_review)
      end

      it "still reverts job to :implemented even when the GitHub review call raises" do
        allow(client_double).to receive(:create_pr_review).and_raise(Octokit::TooManyRequests)
        described_class.after_fail(workflow)
        expect(job.reload).to be_implemented
      end
    end

    context "when the job is a same-repo PR" do
      let(:job) { same_repo_job }
      let(:workflow) { Workflow.create!(job: job, trigger_kind: "external_pr_ingest") }

      it "drives the job to :failed" do
        described_class.after_fail(workflow)
        expect(job.reload).to be_failed
      end

      it "does not post a review comment" do
        described_class.after_fail(workflow)
        expect(client_double).not_to have_received(:create_pr_review)
      end
    end

    context "error resilience" do
      let(:job) { fork_job }
      let(:workflow) { Workflow.create!(job: job, trigger_kind: "external_pr_ingest") }

      it "does not propagate unexpected errors from after_fail" do
        allow(GithubClient).to receive(:for).and_raise(RuntimeError, "unexpected")
        expect { described_class.after_fail(workflow) }.not_to raise_error
      end
    end
  end

  describe ".trigger_kind" do
    it "returns external_pr_ingest" do
      expect(described_class.trigger_kind).to eq("external_pr_ingest")
    end
  end
end
