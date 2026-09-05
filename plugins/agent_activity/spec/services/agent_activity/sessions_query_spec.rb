require "rails_helper"

RSpec.describe AgentActivity::SessionsQuery do
  let!(:operator) { Factories.user(admin: false) }
  let(:my_repository) { Factories.repository(user: operator) }
  let(:other_repository) { Factories.repository(user: Factories.user) }

  def sessions_for(scope:, user:, page: 1, per: 25)
    filter = AgentActivity::Filter.new(nil, user: user)
    described_class.call(scope: scope, user: user, filter: filter, page: page, per: per)
  end

  it "only includes Runs whose Step is agentic" do
    job = Factories.job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 1.minute.ago })
    Factories.job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "prepare" }, run_attrs: { state: "running", started_at: 1.minute.ago })

    result = sessions_for(scope: :mine, user: operator)

    expect(result[:rows].map(&:job_id)).to eq([ job.id ])
  end

  describe "scope: :mine" do
    it "includes sessions on repositories the user belongs to" do
      job = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end

    it "excludes sessions on repositories the user does not belong to and does not own" do
      Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows]).to be_empty
    end

    it "includes a Job the user effectively owns even on a repository they don't otherwise belong to" do
      job = Factories.job_with_run(repository: other_repository, user: operator, owner_user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end
  end

  describe "scope: :admin" do
    it "includes sessions across every repository" do
      job = Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :admin, user: Factories.user(admin: true))

      expect(result[:rows].map(&:job_id)).to include(job.id)
    end
  end

  describe "running_count" do
    it "counts running sessions within scope regardless of pagination/filter" do
      Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })
      Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 10.minutes.ago, finished_at: 5.minutes.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:running_count]).to eq(1)
      expect(result[:total]).to eq(2)
    end
  end

  describe "pagination" do
    it "limits and pages rows while total reflects the full filtered count" do
      3.times { |n| Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      result = sessions_for(scope: :mine, user: operator, page: 1, per: 2)

      expect(result[:rows].size).to eq(2)
      expect(result[:total]).to eq(3)
      expect(result[:page]).to eq(1)
      expect(result[:per]).to eq(2)
    end
  end

  describe "ordering" do
    it "orders most-recently-started first" do
      older = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 20.minutes.ago, finished_at: 15.minutes.ago })
      newer = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to eq([ newer.id, older.id ])
    end
  end
end
