require "rails_helper"

RSpec.describe WorkflowWarnings::FileFixJob do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:warning) do
    WorkflowWarnings.record!(
      workflow: workflow,
      kind: "grader_side_effect",
      title: "Grader left changes",
      suggested_prompt: "Fix the grader"
    )
  end

  describe ".call" do
    it "creates a direct Job from the prompt and stamps created_job on the warning" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "Fix the grader please")

      expect(result).to be_ok
      expect(result.job).to be_persisted
      expect(result.job.kind).to eq("direct")
      expect(result.job.issue_number).to be_nil
      expect(result.job.issue_body).to eq("Fix the grader please")
      expect(result.job.repository).to eq(job.repository)
      expect(result.warning.created_job).to eq(result.job)
      expect(result.message).to include(result.job.slug)
    end

    it "returns the existing created Job without creating another one" do
      first = described_class.call(warning: warning, actor: job.user, prompt: "Fix the grader please")

      expect {
        second = described_class.call(warning: warning.reload, actor: job.user, prompt: "Fix the grader another way")

        expect(second).to be_ok
        expect(second.job).to eq(first.job)
        expect(second.warning.created_job).to eq(first.job)
      }.not_to change(Job, :count)
    end

    it "creates only one Job when two callers file the same warning concurrently" do
      warning.id
      ready = Queue.new
      start = Queue.new

      invoke = lambda do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          described_class.call(warning: WorkflowWarning.find(warning.id), actor: job.user, prompt: "Fix the grader please")
        end
      end

      threads = 2.times.map { Thread.new { invoke.call } }
      2.times { ready.pop }

      expect {
        2.times { start << true }
        results = threads.map(&:value)

        expect(results).to all(be_ok)
        expect(results.map { |result| result.job.id }.uniq).to contain_exactly(warning.reload.created_job_id)
      }.to change(Job, :count).by(1)
    ensure
      threads&.each(&:kill)
    end

    it "strips and requires a non-blank prompt" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "   ")

      expect(result).not_to be_ok
      expect(result.message).to match(/blank/i)
      expect(warning.reload.created_job).to be_nil
    end

    it "allows the operator-edited prompt to differ from suggested_prompt" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "A completely different prompt")

      expect(result.job.issue_body).to eq("A completely different prompt")
    end
  end
end
