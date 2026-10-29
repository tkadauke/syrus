require "rails_helper"

RSpec.describe JobExecutionAccessors do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 1) }

  describe "#head_sha" do
    it "uses the latest nonblank head from a loaded runs association without querying" do
      older = job.runs.create!(trigger_kind: "initial", agent_provider: job.agent_provider, head_sha: "older")
      newer = job.runs.create!(trigger_kind: "retry", agent_provider: job.agent_provider, head_sha: "newer")
      job.runs.create!(trigger_kind: "retry", agent_provider: job.agent_provider, head_sha: nil)
      older.update_column(:created_at, 2.minutes.ago)
      newer.update_column(:created_at, 1.minute.ago)
      job.runs.reload

      run_queries = 0
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        run_queries += 1 if sql.match?(/\ASELECT/i) && sql.include?('FROM "runs"')
      end

      head_sha = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { job.head_sha }

      expect(head_sha).to eq("newer")
      expect(run_queries).to eq(0)
    end

    it "keeps the database-backed latest-run ordering when runs are not loaded" do
      job.runs.create!(trigger_kind: "initial", agent_provider: job.agent_provider, head_sha: "older")
      latest = job.runs.create!(trigger_kind: "retry", agent_provider: job.agent_provider, head_sha: "latest")
      latest.update_column(:created_at, 1.minute.from_now)
      job.association(:runs).reset

      expect(job.head_sha).to eq("latest")
    end
  end
end
