require "rails_helper"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  describe "#job_json" do
    it "includes a compact worker health correlation summary" do
      job = Factories.job(repository: repo)
      run = job.initial_run
      run.workflow.update!(worker_hostname: "worker-a")
      run.update!(started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      WorkerHostHealthSample.create!(
        hostname: "worker-a",
        role: "worker",
        version: "abc123",
        observed_at: 5.minutes.ago,
        cpu_pressure_some: 60.0
      )

      payload = payload_for(job)

      expect(payload.dig(:job, :worker_health_correlation)).to include(
        runs_analyzed: 1,
        pressure_run_count: 1
      )
      expect(payload.dig(:job, :worker_health_correlation, :latest_pressure_runs).first).to include(
        run_id: run.id,
        step_kind: run.step.kind
      )
    end

    it "includes configured deployment stage statuses in the Job detail shape" do
      staging = SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil)
      production = SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil)
      allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repo).and_return(
        RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
      )
      job = Factories.job_record(user: user, repository: repo, landed_sha: "merge-sha", state: "closed")
      reached_at = Time.zone.parse("2026-07-30 12:00:00 UTC")
      JobDeploymentStageStatus.create!(job: job, stage_name: "staging", reached_at: reached_at, tag_sha: "tag-sha")

      expect(payload_for(job).dig(:job, :deployment_stages)).to eq([
        {
          name: "staging",
          label: "Staging",
          reached: true,
          reached_at: reached_at.iso8601,
          tag_sha: "tag-sha"
        },
        {
          name: "production",
          label: "Production",
          reached: false,
          reached_at: nil,
          tag_sha: nil
        }
      ])
    end

    it "omits deployment stages when the repository has none configured" do
      allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repo).and_return(
        RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: "no deployment_stages configured")
      )
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).fetch(:job)).not_to have_key(:deployment_stages)
    end

    it "links a chat-created Job back to the proposal message" do
      chat = ChatSession.create!(user: user, repository: repo, title: "Release planning")
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      proposal = chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      expect(payload_for(job).dig(:job, :source_chat)).to include(
        chat_id: chat.id,
        chat_title: "Release planning",
        proposal_id: proposal.id,
        proposal_kind: "syrus_issue",
        message_id: message.id,
        path: "/chats/#{chat.id}#message-#{message.id}",
        label: "Job proposal in Release planning"
      )
    end

    it "falls back to the Job Epic's proposal when the Job has no direct proposal" do
      chat = ChatSession.create!(user: user, repository: repo)
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)
      proposal = chat.proposals.create!(
        slug: "auth",
        title: "Auth",
        body: "Group auth work.",
        kind: "epic",
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Epic proposed." })

      expect(payload_for(job).dig(:job, :source_chat)).to include(
        chat_id: chat.id,
        proposal_id: proposal.id,
        proposal_kind: "epic",
        message_id: message.id,
        path: "/chats/#{chat.id}#message-#{message.id}",
        label: "Epic proposal"
      )
    end

    it "includes the no-PR reason recorded by a reconciliation workflow" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Reconcile stack")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "no_pr_reason" => {
            "kind" => "empty_reconciliation",
            "message" => "No PR was opened because reconciliation made no additional changes beyond syrus/direct-parent.",
            "base_branch" => "syrus/direct-parent"
          }
        }
      )

      expect(payload_for(job).dig(:job, :no_pr_reason)).to include(
        "kind" => "empty_reconciliation",
        "message" => "No PR was opened because reconciliation made no additional changes beyond syrus/direct-parent.",
        "base_branch" => "syrus/direct-parent"
      )
    end
  end

  describe "#origin_chat_json" do
    it "returns the originating chat session and message for a directly proposed job" do
      chat = ChatSession.create!(user: user, repository: repo, title: "Release planning")
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      proposal = chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      expect(payload_for(job)[:origin_chat]).to eq(
        chat_session_id: chat.id,
        message_id: message.id
      )
    end

    it "falls back to the job epic's proposal when the job has no direct proposal" do
      chat = ChatSession.create!(user: user, repository: repo)
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)
      proposal = chat.proposals.create!(
        slug: "auth",
        title: "Auth",
        body: "Group auth work.",
        kind: "epic",
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Epic proposed." })

      expect(payload_for(job)[:origin_chat]).to eq(
        chat_session_id: chat.id,
        message_id: message.id
      )
    end

    it "returns nil when neither the job nor its epic has a chat proposal" do
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)

      expect(payload_for(job)[:origin_chat]).to be_nil
    end

    it "returns nil when a proposal exists without a linked chat message" do
      chat = ChatSession.create!(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )

      expect(payload_for(job)[:origin_chat]).to be_nil
    end
  end

  describe "#deployment_stages_json" do
    let(:stages) do
      [
        SyrusYml::DeploymentStage.new(name: "staging", label: "On Staging", tag: "staging", tag_pattern: nil),
        SyrusYml::DeploymentStage.new(name: "production", label: "In Production", tag: "production", tag_pattern: nil),
        SyrusYml::DeploymentStage.new(name: "public", label: "Released to Public", tag: "release", tag_pattern: nil)
      ]
    end

    before do
      allow(RepoDeploymentStagesReader).to receive(:for_repository)
        .with(repo)
        .and_return(RepoDeploymentStagesReader::Result.new(stages: stages, source: ".syrus.yml", note: nil))
    end

    it "omits deployment stages when the job has not landed" do
      job = Factories.job_record(repository: repo, landed_sha: nil)

      expect(payload_for(job)).not_to have_key(:deployment_stages)
    end

    it "returns configured stages in order with reached timestamps" do
      reached_at = Time.zone.parse("2026-07-30T12:00:00Z")
      job = Factories.job_record(repository: repo, landed_sha: "abc123")
      job.deployment_stage_statuses.create!(stage_name: "staging", reached_at: reached_at, tag_sha: "tagsha")

      expect(payload_for(job)[:deployment_stages]).to eq([
        { name: "staging", label: "On Staging", reached: true, reached_at: "2026-07-30T12:00:00Z", tag_sha: "tagsha" },
        { name: "production", label: "In Production", reached: false, reached_at: nil, tag_sha: nil },
        { name: "public", label: "Released to Public", reached: false, reached_at: nil, tag_sha: nil }
      ])
    end

    it "omits deployment stages when the repository has no configured stages" do
      job = Factories.job_record(repository: repo, landed_sha: "abc123")
      allow(RepoDeploymentStagesReader).to receive(:for_repository)
        .with(repo)
        .and_return(RepoDeploymentStagesReader::Result.new(stages: [], source: ".syrus.yml", note: nil))

      expect(payload_for(job)).not_to have_key(:deployment_stages)
    end
  end

  describe "#test_plan_json" do
    it "returns nil when the job has no workflows" do
      job = Factories.job_record(repository: repo)

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "returns the test plan artifact in a stable top-level shape" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "test_plan" => {
            "steps" => [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
            "notes" => "Check the Summary tab."
          }
        }
      )

      expect(payload_for(job)[:test_plan]).to eq(
        workflow_id: workflow.id,
        steps: [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
        notes: "Check the Summary tab."
      )
    end

    it "picks the latest workflow with a test plan artifact" do
      job = Factories.job_record(repository: repo)
      older = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run old tests" ], "notes" => "old" } }
      )
      newer = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run new tests" ], "notes" => nil } }
      )

      expect(payload_for(job)[:test_plan]).to include(
        workflow_id: newer.id,
        steps: [ "Run new tests" ],
        notes: nil
      )
      expect(payload_for(job)[:test_plan][:workflow_id]).not_to eq(older.id)
    end

    it "treats a workflow with empty steps as absent" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: { "test_plan" => { "steps" => [], "notes" => "Nothing to run." } }
      )

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "ignores unfinished and non-canonical follow-up workflow test plans" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run unfinished tests" ], "notes" => nil } }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        created_at: 30.minutes.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run follow-up tests" ], "notes" => nil } }
      )

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "uses canonical metadata test plans from succeeded feedback workflows" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: {
          "job_metadata" => {
            "changed" => true,
            "test_plan" => {
              "steps" => [ "Run bin/rspec spec/services/job_metadata_refresh_applier_spec.rb" ],
              "notes" => "Review refreshed PR body."
            }
          }
        }
      )

      expect(payload_for(job)[:test_plan]).to eq(
        workflow_id: workflow.id,
        steps: [ "Run bin/rspec spec/services/job_metadata_refresh_applier_spec.rb" ],
        notes: "Review refreshed PR body."
      )
    end
  end

  describe "#summary_json" do
    it "prefers canonical metadata summaries from succeeded workflows over run summaries" do
      job = Factories.job(repository: repo)
      job.initial_run.update!(agent_summary: "Stale initial summary.", finished_at: 2.hours.ago)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        finished_at: 1.hour.ago,
        artifacts: {
          "job_metadata" => {
            "changed" => true,
            "summary" => "The current intent preserves provider switching."
          }
        }
      )

      expect(payload_for(job)[:summary]).to eq(
        workflow_id: workflow.id,
        text: "The current intent preserves provider switching.",
        finished_at: workflow.finished_at.iso8601
      )
    end

    it "ignores canonical metadata from unfinished workflows" do
      job = Factories.job(repository: repo)
      job.initial_run.update!(agent_summary: "Latest completed run summary.", finished_at: 2.hours.ago)
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "running",
        artifacts: {
          "job_metadata" => {
            "changed" => true,
            "summary" => "Unfinished metadata."
          }
        }
      )

      expect(payload_for(job)[:summary]).to include(
        run_id: job.initial_run.id,
        text: "Latest completed run summary."
      )
    end
  end

  describe "#has_test_results?" do
    it "returns false when the job has no runs" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job)[:has_test_results]).to be(false)
    end

    it "returns false when runs exist but none have test results" do
      job = Factories.job(user: user, repository: repo)

      expect(payload_for(job)[:has_test_results]).to be(false)
    end

    it "returns true when at least one run has a TestRun" do
      job = Factories.job(user: user, repository: repo)
      run = job.initial_run
      TestRun.create!(
        run: run,
        repository: repo,
        grader_name: "rspec",
        total_count: 1,
        passed_count: 1,
        failed_count: 0,
        skipped_count: 0,
        error_count: 0
      )

      expect(payload_for(job)[:has_test_results]).to be(true)
    end
  end

  describe "#workflows_json" do
    it "includes the active spawned process for running runs" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )
      finished = SpawnedProcess.create!(
        kind: "prepare",
        command: "old command",
        workdir: "/tmp/old",
        hostname: "worker-1",
        started_at: 3.minutes.ago,
        finished_at: 2.minutes.ago,
        run: run,
        workflow: workflow
      )
      active = SpawnedProcess.create!(
        kind: "prepare",
        command: "bundle exec rspec",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        started_at: 1.minute.ago,
        last_chunk_at: 30.seconds.ago,
        wall_timeout_s: 600,
        silent_timeout_s: 120,
        run: run,
        workflow: workflow
      )

      active_process = payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0, :active_process)

      expect(active_process).to include(
        id: active.id,
        kind: "prepare",
        command: "bundle exec rspec",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        wall_timeout_s: 600,
        silent_timeout_s: 120
      )
      expect(active_process[:id]).not_to eq(finished.id)
    end

    it "includes compact worker health correlation on each run payload" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", worker_hostname: "worker-1")
      step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "succeeded", details: { "name" => "rspec" })
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        started_at: 10.minutes.ago,
        finished_at: 1.minute.ago
      )
      WorkerHostHealthSample.create!(
        hostname: "worker-1",
        role: "worker",
        version: "abc123",
        observed_at: 5.minutes.ago,
        cpu_pressure_some: 52.0
      )

      correlation = payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0, :worker_health_correlation)

      expect(correlation).to include(
        run_id: run.id,
        primary_hostname: "worker-1",
        sample_count: 1,
        command_spans: []
      )
      expect(correlation.dig(:pressure, :level)).to eq("critical")
    end

    it "serializes only workflow artifact fields needed by the detail UI" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "summary" => "Done",
          "iterations" => [ { "name" => "rspec", "output" => "large" } ],
          "coverage" => {
            "summary" => { "lines_pct" => 90.0 },
            "files" => { "app.rb" => { "lines_pct" => 90.0 } },
            "diff_annotations" => { "app.rb" => { "1" => "covered" } },
            "pr_comment_body" => "large markdown"
          }
        }
      )

      artifacts = payload_for(job).dig(:workflows, 0, :artifacts)

      expect(artifacts).to include("summary" => "Done")
      expect(artifacts).not_to have_key("iterations")
      expect(artifacts.dig("coverage", "summary")).to eq("lines_pct" => 90.0)
      expect(artifacts["coverage"]).not_to have_key("diff_annotations")
      expect(artifacts["coverage"]).not_to have_key("pr_comment_body")
    end
  end

  describe "#feedback_history_json" do
    it "returns chat feedback workflow artifacts in chronological order" do
      job = Factories.job_record(repository: repo)
      newer = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "chat_feedback" => "New feedback" }
      )
      older = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Old feedback" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 3.hours.ago,
        artifacts: { "chat_feedback" => "PR feedback artifact" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "failed",
        created_at: 30.minutes.ago,
        artifacts: { "chat_feedback" => "" }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          { kind: "chat_feedback", body: "Old feedback", created_at: older.created_at.iso8601, state: "succeeded", feedback_source: nil },
          { kind: "chat_feedback", body: "New feedback", created_at: newer.created_at.iso8601, state: "running", feedback_source: nil }
        ]
      )
    end

    it "returns PR comment workflow artifacts with author attribution" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: {
          "pr_comments" => [
            { "author" => "alice", "body" => "Please cover the blank state." },
            { "author" => "bob", "body" => "This should mention review feedback." }
          ]
        }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          {
            kind: "pr_comment",
            body: "@alice: Please cover the blank state.\n\n@bob: This should mention review feedback.",
            created_at: workflow.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil
          }
        ]
      )
    end

    it "excludes PR comment workflows without comments" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: { "pr_comments" => [] }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: {}
      )

      expect(payload_for(job)[:feedback_history]).to eq([])
    end

    it "interleaves chat feedback and PR comments chronologically" do
      job = Factories.job_record(repository: repo)
      chat_workflow = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Chat feedback" }
      )
      pr_workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "PR feedback" } ] }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          { kind: "chat_feedback", body: "Chat feedback", created_at: chat_workflow.created_at.iso8601, state: "succeeded", feedback_source: nil },
          { kind: "pr_comment", body: "@reviewer: PR feedback", created_at: pr_workflow.created_at.iso8601, state: "running", feedback_source: nil }
        ]
      )
    end

    it "excludes non feedback workflow trigger kinds" do
      job = Factories.job_record(repository: repo)
      %w[initial retry ci_failure].each do |trigger_kind|
        Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          state: "succeeded",
          artifacts: {
            "chat_feedback" => "#{trigger_kind} chat feedback",
            "pr_comments" => [ { "author" => "reviewer", "body" => "#{trigger_kind} PR feedback" } ]
          }
        )
      end

      expect(payload_for(job)[:feedback_history]).to eq([])
    end
  end

  describe "#job_json main_branch_repair" do
    it "is false for a regular direct job" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Add a feature")

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(false)
    end

    it "is true for a direct job with the main branch repair title" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: Job::MAIN_BRANCH_REPAIR_TITLE)

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(true)
    end

    it "is true for a job with system_kind main_branch_repair" do
      job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "direct",
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: "Fix broken main branch"
      )

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(true)
    end

    it "is false for a regular issue job" do
      job = Factories.job_record(user: user, repository: repo, issue_number: 42)

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(false)
    end
  end

  describe "#actions_json can_restart" do
    it "is true for an issue job with no active runs" do
      job = Factories.job_record(repository: repo, issue_number: 5)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a cron job even with no active runs" do
      scheduled_task = ScheduledTask.create!(
        user: user,
        repository: repo,
        name: "Nightly check",
        cron_expression: "0 3 * * *",
        prompt: "Check the repo.",
        kind: "cron",
        pr_pileup_policy: "skip"
      )
      job = Factories.job_record(user: user, repository: repo, kind: "cron", issue_number: nil,
                                 scheduled_task: scheduled_task)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a direct job with no active runs" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: "Fix it")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a no_change_needed job" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end
  end

  describe "#actions_json for no_change_needed state" do
    def create_no_change_workflow(job)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        agent_provider: job.agent_provider,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      step = workflow.steps.create!(
        kind: "implement",
        position: 1,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "agent produced no changes")
      workflow
    end

    it "suppresses retry_implementation_action for no_change_needed jobs" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")
      create_no_change_workflow(job)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
    end

    it "suppresses retry_failed_step_action for no_change_needed jobs" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")
      create_no_change_workflow(job)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_failed_step_action]).to be_nil
    end

    it "allows closing a no_change_needed job" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")

      expect(payload_for(job).dig(:actions, :can_cancel)).to be(true)
    end
  end

  describe "#actions_json retry actions" do
    def create_failed_workflow(job, trigger_kind:, failed_step_kind:)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: trigger_kind,
        agent_provider: job.agent_provider,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow.steps.create!(
        kind: failed_step_kind,
        position: 1,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow
    end

    it "offers failed-step retry and implementation retry for implementation-shaped failures" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "implement")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(true)
      expect(actions[:retry_implementation_action]).to include(
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      )
      expect(actions[:can_retry_from_failed_step]).to be(true)
      expect(actions[:retry_failed_step_action]).to include(
        key: "retry_failed_step",
        label: "Retry failed step",
        workflow_id: workflow.id,
        step_kind: "implement"
      )
    end

    it "does not offer implementation retry for post-implementation workflow failures" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to include(
        label: "Retry failed step",
        workflow_id: workflow.id,
        step_kind: "pr_open"
      )
    end

    it "offers implementation retry for a reopened cancelled initial workflow" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "triaging",
        closure_reason: nil,
        finished_at: nil
      )
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        agent_provider: job.agent_provider,
        state: "cancelled",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(true)
      expect(actions[:retry_implementation_action]).to include(
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      )
      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_failed_step_action]).to be_nil
    end

    it "labels landing workflow retries separately from implementation retries" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "implemented",
        landing_failure_reason: "auto_merge: required grader failed"
      )
      workflow = create_failed_workflow(job, trigger_kind: "auto_merge", failed_step_kind: "auto_merge")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to include(
        label: "Retry landing step",
        workflow_id: workflow.id,
        step_kind: "auto_merge"
      )
    end

    it "suppresses all retry actions for infrastructure (main_grader) workflows" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      create_failed_workflow(infra_job, trigger_kind: "main_grader", failed_step_kind: "grader")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      actions = payload_for(infra_job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to be_nil
    end
  end

  describe "#actions_json can_reopen" do
    it "is true for a closed non-infrastructure job" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "closed",
        closure_reason: "pr_merged"
      )

      expect(payload_for(job).dig(:actions, :can_reopen)).to be(true)
    end

    it "is false for a closed infrastructure (main_grader) job" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      Workflow.create!(job: infra_job, trigger_kind: "main_grader", user: user, state: "succeeded")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      expect(payload_for(infra_job).dig(:actions, :can_reopen)).to be(false)
    end

    it "is false for an open job" do
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_reopen)).to be(false)
    end
  end

  describe "#landing_queue_entry blocker jobs" do
    let(:blocker_repo) { Factories.repository(user: user) }

    it "includes repository, latest workflow fields, and timestamps for each blocker job" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 10, issue_title: "Unfinished prerequisite")
      workflow = Workflow.create!(job: blocker_job, trigger_kind: "initial", state: "running", started_at: 1.hour.ago)

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)
      approved_job.reload

      entry = payload_for(approved_job)[:landing_queue_entry]
      blocker = entry[:blocker_jobs].find { |b| b[:id] == blocker_job.id }

      expect(blocker).to include(
        id: blocker_job.id,
        repository: hash_including(id: blocker_repo.id, slug: blocker_repo.slug),
        latest_workflow_id: workflow.id,
        latest_workflow_state: "running",
        latest_workflow_trigger_kind: "initial",
        created_at: blocker_job.created_at.iso8601
      )
    end

    it "exposes nil latest_workflow_id for a blocker job with no workflows" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "queued", issue_number: 11)

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)
      approved_job.reload

      entry = payload_for(approved_job)[:landing_queue_entry]
      blocker = entry[:blocker_jobs].find { |b| b[:id] == blocker_job.id }

      expect(blocker[:latest_workflow_id]).to be_nil
    end

    it "omits the queue position for blocked landing queue entries" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 10)
      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      expect(payload_for(approved_job.reload).dig(:landing_queue_entry, :position)).to be_nil
    end
  end

  describe "start_blocked_reason" do
    it "returns nil when the job has no queued workflow with a block reason" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")

      expect(payload_for(job).dig(:job, :start_blocked_reason)).to be_nil
      expect(payload_for(job).dig(:job, :start_blocked_at)).to be_nil
      expect(payload_for(job).dig(:job, :start_blocked_details)).to be_nil
    end

    it "returns the block reason from the queued workflow's artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "stack_fan_in_base_unavailable",
          "start_blocked_at" => "2026-07-01T12:00:00Z",
          "start_blocked_details" => {
            "kind" => "fan_in_base_unavailable",
            "message" => "multiple dependency branches are ready",
            "dependencies" => [ { "slug" => "JOB-1574" } ]
          }
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("stack_fan_in_base_unavailable")
      expect(result.dig(:job, :start_blocked_at)).to eq("2026-07-01T12:00:00Z")
      expect(result.dig(:job, :start_blocked_details)).to include(
        "kind" => "fan_in_base_unavailable",
        "message" => "multiple dependency branches are ready",
        "dependencies" => [ { "slug" => "JOB-1574" } ]
      )
    end
  end

  describe "dependencies" do
    it "serializes epic dependency targets" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocker = Factories.epic(user: user, repository: repo, title: "Pave the road", state: "ready")
      JobDependency.create!(job: job, depends_on_epic: blocker, source: "manual", created_by_user: user)

      dependency = payload_for(job).fetch(:dependencies).sole

      expect(dependency[:succeeded]).to be(false)
      expect(dependency[:depends_on_job]).to be_nil
      expect(dependency[:depends_on_epic]).to include(
        id: blocker.id,
        display_number: blocker.slug,
        title: "Pave the road",
        state: "ready",
        repository_slug: repo.slug,
        epic_path: "/epics/#{blocker.id}"
      )
    end
  end
end
