require "rails_helper"

RSpec.describe "maintenance task definitions" do
  describe MaintenanceTasks::Definitions::AgentsBackfill do
    let(:definition) { described_class.new }
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    it "bulk creates missing Agent rows for runs" do
      job = Factories.job_with_run(user: user, repository: repository)
      run = job.runs.first
      Agent.where(resumable: run).delete_all
      task = maintenance_task_for(definition)

      result = definition.perform_batch(task)

      expect(result.processed).to eq(1)
      expect(result.message).to include("Run Agent")
      expect(Agent.find_by!(resumable: run)).to be_present
    end

    it "bulk attaches spawned processes to existing run and chat agents" do
      job = Factories.job_with_run(user: user, repository: repository)
      run = job.runs.first
      chat = ChatSession.create!(user: user, repository: repository, chat_provider: "codex")
      run_agent = Agent.find_or_create_for!(run)
      chat_agent = Agent.find_or_create_for!(chat)
      run_process = SpawnedProcess.create!(
        run: run,
        workflow: run.workflow,
        kind: "agent",
        command: "true",
        hostname: "worker-1",
        started_at: Time.current
      )
      chat_process = SpawnedProcess.create!(
        chat_session: chat,
        kind: "chat_prepare",
        command: "true",
        hostname: "worker-1",
        started_at: Time.current
      )
      SpawnedProcess.where(id: [ run_process.id, chat_process.id ]).update_all(agent_id: nil)
      task = maintenance_task_for(definition)

      result = definition.perform_batch(task)

      expect(result.processed).to eq(2)
      expect(result.message).to include("spawned process")
      expect(run_process.reload.agent).to eq(run_agent)
      expect(chat_process.reload.agent).to eq(chat_agent)
    end

    it "does not count orphaned spawned processes as attachable work" do
      SpawnedProcess.create!(
        run_id: 123_456_789,
        kind: "agent",
        command: "true",
        hostname: "worker-1",
        started_at: Time.current
      )

      expect(definition.estimate_total_units).to eq(0)
    end
  end

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

    it "does not treat a matching sha on a different landable as a completed merge-train backfill" do
      epic = Factories.epic(user: user, repository: repository)
      job = Factories.job_record(
        user: user,
        repository: repository,
        state: "closed",
        issue_number: 104,
        pr_number: 105,
        landed_sha: "abc123"
      )
      train = MergeTrain.create!(
        repository: repository,
        epic: epic,
        base_branch: "main",
        integration_branch: "syrus/merge-train-epic-#{epic.id}-1",
        integration_sha: "abc123",
        state: "succeeded"
      )
      MergeTrainMember.create!(merge_train: train, job: job, position: 0)
      LandedCommit.create!(landable: job, sha: "abc123", kind: "implementation", position: 0)

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

    it "records errored repositories as unresolved and fails completion instead of reporting success" do
      Factories.job_record(
        user: user,
        repository: repository,
        state: "closed",
        issue_number: 106,
        pr_number: 107,
        landed_sha: "ghi789"
      )
      task = maintenance_task_for(definition)
      service_result = Jobs::LandedCommitsBackfill::Result.new(checked: 1, recorded: 0, commits_recorded: 0, skipped: 0, errors: 1)
      service = instance_double(Jobs::LandedCommitsBackfill, call: service_result)
      allow(Jobs::LandedCommitsBackfill).to receive(:new).with(repository: repository).and_return(service)

      result = definition.perform_batch(task)

      expect(result.failed).to eq(1)
      expect(result.level).to eq("warning")
      expect(task.checkpoint["processed_repository_ids"]).to include(repository.id)
      expect(task.checkpoint["unresolved_repositories"]).to contain_exactly(
        hash_including("id" => repository.id, "slug" => repository.slug, "errors" => 1)
      )

      expect { definition.perform_batch(task) }
        .to raise_error(MaintenanceTasks::Definitions::LandedCommitsBackfill::UnresolvedLandingsError, /#{Regexp.escape(repository.slug)}/)
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

  describe MaintenanceTasks::Definitions::TestInsightsWipRepairFailureBackfill do
    let(:definition) { described_class.new }

    before do
      result_struct = Struct.new(:done, :processed, :next_after_id, keyword_init: true)
      stub_const("TestInsights::WipRepairFailureBackfill", Class.new do
        define_singleton_method(:pending_count) { |after_id: 0| [ 5 - after_id, 0 ].max }

        define_method(:call) do |after_id: 0, limit:|
          result_struct.new(done: true, processed: 5, next_after_id: after_id + 5)
        end
      end)
    end

    it "wraps the plugin backfill service when Test Insights is installed" do
      expect(definition.estimate_total_units).to eq(5)

      task = maintenance_task_for(definition)
      result = definition.perform_batch(task)

      expect(result.done).to be(true)
      expect(result.processed).to eq(5)
      expect(task.checkpoint["after_id"]).to eq(5)
    end

    it "reports not installed when Test Insights is unavailable" do
      hide_const("TestInsights::WipRepairFailureBackfill")

      result = definition.perform_batch(maintenance_task_for(definition))

      expect(result.done).to be(true)
      expect(result.processed).to eq(0)
      expect(result.message).to include("not installed")
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

    it "delegates plugin-owned search backfills through the global search source extension point" do
      provider = Class.new do
        class << self
          attr_reader :received_task

          def search_database_rebuild_key = "jobs"
          def search_database_rebuild_units = 2
          def search_database_rebuild_pending? = true

          def search_database_rebuild_batch(task:)
            @received_task = task
            MaintenanceTasks::Definitions::Base::Result.new(done: false, processed: 2, failed: 0, message: "Indexed 2 job(s).", level: "progress")
          end
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with("global_search:source").and_return([ provider ])
      task = maintenance_task_for(definition)
      task.checkpoint["schema_prepared"] = true

      result = definition.perform_batch(task)

      expect(result.processed).to eq(2)
      expect(provider.received_task).to eq(task)
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
