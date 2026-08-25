require "rails_helper"

RSpec.describe Skills::ExplainFailingCi do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:client) { instance_double(GithubClient) }

  describe ".definition" do
    it "declares a required job_id parameter" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("explain-failing-ci")
      expect(definition.description).to match(/read-only/i)
      expect(definition.parameters.size).to eq(1)

      job_id = definition.parameters.first
      expect(job_id.key).to eq("job_id")
      expect(job_id.type).to eq("integer")
      expect(job_id.required).to eq(true)
    end

    it "renders the {{job_id}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{job_id}}")
    end

    it "instructs the agent to explain rather than fix, and to make no changes" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/read-only report/i)
      expect(instructions).to match(/do not attempt a fix/i)
      expect(instructions).to match(/do not commit anything/i)
    end

    it "does not report a pre-fetch digest without args and a repository" do
      expect(described_class.definition.instructions).not_to include("Automated pre-fetch results")
    end
  end

  describe ".definition(args:, repository:)" do
    def definition_for(job_id)
      described_class.definition(args: { "job_id" => job_id }, repository: repository)
    end

    it "does not report a pre-fetch digest without a repository" do
      instructions = described_class.definition(args: { "job_id" => 1 }).instructions

      expect(instructions).not_to include("Automated pre-fetch results")
    end

    it "reports that the target Job was not found when job_id doesn't resolve in this repository" do
      instructions = definition_for(999_999).instructions

      expect(instructions).to include("Automated pre-fetch results")
      expect(instructions).to match(/Job id 999999 was not found in this repository/)
    end

    it "does not leak a Job that belongs to a different repository" do
      other_repository = Factories.repository(user: user, owner: "acme", name: "other")
      other_job = Factories.job_record(user: user, repository: other_repository, pr_number: 5)

      instructions = definition_for(other_job.id).instructions

      expect(instructions).to match(/was not found in this repository/)
    end

    it "reports that the target Job has no pull request when it has none" do
      job = Factories.job_record(user: user, repository: repository, pr_number: nil)

      instructions = definition_for(job.id).instructions

      expect(instructions).to match(/has no associated pull request to check/)
    end

    context "with a Job that has a pull request" do
      let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 7) }
      let(:sha) { "abc1234567890000000000000000000000000000" }

      before do
        pr = double("PullRequest", head: double("Head", sha: sha), base: double("Base", sha: "base123"))
        allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
        allow(client).to receive(:pull_request).with("acme/widgets", 7, bypass_cache: true).and_return(pr)
      end

      it "reports checks are still pending when GitHub reports no completed failures yet" do
        allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(
          pending?: true, any_failed?: false, all_passed?: false, failed_checks: []
        )

        instructions = definition_for(job.id).instructions

        expect(instructions).to match(/still running/i)
      end

      it "includes the failing check digest when a check has genuinely failed" do
        allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(
          pending?: false,
          any_failed?: true,
          all_passed?: false,
          failed_checks: [
            { name: "rspec", conclusion: "failure", summary: "1 example, 1 failure", html_url: "https://github.com/acme/widgets/runs/1" }
          ]
        )

        instructions = definition_for(job.id).instructions

        expect(instructions).to match(/CI is failing for PR #7/)
        expect(instructions).to include("## rspec — failure")
        expect(instructions).to include("1 example, 1 failure")
      end

      it "reports a fetch failure instead of raising when GitHub errors out" do
        allow(client).to receive(:check_runs_detail_for).and_raise(Octokit::NotFound.new)

        instructions = definition_for(job.id).instructions

        expect(instructions).to match(/could not fetch ci status/i)
      end
    end
  end
end
