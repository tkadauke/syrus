require "rails_helper"

RSpec.describe "maintenance task definitions" do
  describe MaintenanceTasks::Definitions::LandedCommitsBackfill do
    let(:definition) { described_class.new }
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "detects repositories with historical landed jobs missing LandedCommit rows" do
      Factories.job_record(
        user: user,
        repository: repository,
        state: "closed",
        issue_number: 100,
        pr_number: 101,
        landed_sha: "abc123"
      )

      expect(definition.estimate_total_units).to eq(1)
    end

    it "processes one repository and checkpoints it" do
      Factories.job_record(
        user: user,
        repository: repository,
        state: "closed",
        issue_number: 102,
        pr_number: 103,
        landed_sha: "def456"
      )
      task = maintenance_task_for(definition)
      service_result = Jobs::LandedCommitsBackfill::Result.new(checked: 1, recorded: 1, commits_recorded: 2, skipped: 0, errors: 0)
      service = instance_double(Jobs::LandedCommitsBackfill, call: service_result)

      expect(Jobs::LandedCommitsBackfill).to receive(:new).with(repository: repository).and_return(service)

      result = definition.perform_batch(task)

      expect(result.processed).to eq(1)
      expect(result.failed).to eq(0)
      expect(task.checkpoint["processed_repository_ids"]).to include(repository.id)
    end
  end

  describe MaintenanceTasks::Definitions::PreemptedExternalPrBackfill do
    let(:definition) { described_class.new }

    it "wraps the one-off external PR repair service" do
      service_result = Jobs::PreemptedExternalPrBackfill::Result.new(checked: 3, reopened: 2, skipped: 1, errors: 0)
      service = instance_double(Jobs::PreemptedExternalPrBackfill, call: service_result)
      allow(Jobs::PreemptedExternalPrBackfill.default_scope).to receive(:count).and_return(3)

      expect(Jobs::PreemptedExternalPrBackfill).to receive(:new).and_return(service)

      result = definition.perform_batch(maintenance_task_for(definition))

      expect(result.done).to be(true)
      expect(result.processed).to eq(3)
      expect(result.message).to include("reopened 2")
    end
  end

  describe MaintenanceTasks::Definitions::StaleInsightBacklogRetirement do
    let(:definition) { described_class.new }

    before do
      stub_const("AgentInsights::StaleBacklogRetirement", Class.new do
        Result = Struct.new(:checked, :retired, :skipped, :errors, keyword_init: true)

        def self.default_scope = OpenStruct.new(count: 4)
        def call = Result.new(checked: 4, retired: 4, skipped: 0, errors: 0)
      end)
    end

    it "wraps the plugin cleanup service when Agent Insights is installed" do
      expect(definition.estimate_total_units).to eq(4)

      result = definition.perform_batch(maintenance_task_for(definition))

      expect(result.done).to be(true)
      expect(result.processed).to eq(4)
      expect(result.message).to include("retired 4")
    end
  end

  describe MaintenanceTasks::Definitions::SearchDatabaseRebuild do
    let(:definition) { described_class.new }

    it "prepares the search schema first" do
      task = maintenance_task_for(definition)

      expect(SyrusSearchDatabaseTasks).to receive(:prepare!).and_return(true)

      result = definition.perform_batch(task)

      expect(result.processed).to eq(1)
      expect(task.checkpoint["schema_prepared"]).to be(true)
    end

    it "indexes jobs through the global search source provider" do
      user = Factories.user
      repository = Factories.repository(user: user)
      job = Factories.job_record(user: user, repository: repository, issue_title: "Rebuild searchable job")
      provider = Class.new do
        @upserted_ids = []

        class << self
          attr_reader :upserted_ids

          def search_table_name = "job_fts"
          def search_id_column = "job_id"
          def records = Job.order(:id)
          def count = Job.count
          def exists? = Job.exists?
          def upsert(record) = @upserted_ids << record.id
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with("global_search:source").and_return([ provider ])

      result = definition.send(:index_jobs, maintenance_task_for(definition))

      expect(result.processed).to eq(1)
      expect(provider.upserted_ids).to eq([ job.id ])
    end
  end

  def maintenance_task_for(definition)
    MaintenanceTask.new(
      definition_key: definition.key,
      task_key: "spec:#{definition.key}:#{SecureRandom.hex(3)}",
      state: "running",
      recurrence: definition.recurrence,
      category: definition.category,
      title: definition.title,
      summary: definition.summary,
      trigger_kind: "spec",
      trigger_key: definition.key,
      required_role: definition.required_role,
      total_units: definition.estimate_total_units,
      batch_size: definition.batch_size,
      max_parallelism: definition.max_parallelism,
      checkpoint: {},
      metadata: {}
    )
  end
end
