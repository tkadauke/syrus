require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  describe "#attachments" do
    it "uses the authenticated app proxy URL for uploaded files" do
      job = Factories.job_record(user: user, repository: repo)
      attachment = job.job_attachments.build(attachment_type: "uploaded_file")
      attachment.file.attach(
        io: StringIO.new("notes"),
        filename: "notes.txt",
        content_type: "text/plain"
      )
      attachment.save!

      expect(payload_for(job).fetch(:attachments)).to include(
        include(
          id: attachment.id,
          file_path: "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}/file",
          content_path: "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}/content",
          app_delete_path: "/api/v1/app/jobs/#{job.id}/attachments/#{attachment.id}"
        )
      )
    end
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

    it "includes a workflow-recorded no-PR reason" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Review stack")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "no_pr_reason" => {
            "kind" => "no_effective_changes",
            "message" => "No PR was opened because the workflow made no effective changes.",
            "base_branch" => "syrus/direct-parent"
          }
        }
      )

      expect(payload_for(job).dig(:job, :no_pr_reason)).to include(
        "kind" => "no_effective_changes",
        "message" => "No PR was opened because the workflow made no effective changes.",
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
      expect(RepoDeploymentStagesReader).not_to receive(:for_repository)

      expect(payload_for(job)).not_to have_key(:deployment_stages)
      expect(payload_for(job).fetch(:job)).not_to have_key(:deployment_stages)
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
    it "does not query command spans or spawned processes once per run" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")

      3.times do |index|
        step = Step.create!(workflow: workflow, kind: "grader", position: index, state: "running")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "running",
          started_at: (index + 2).minutes.ago
        )
        SpawnedProcess.create!(
          kind: "grader",
          command: "bin/rspec",
          workdir: "/tmp/repo",
          hostname: "worker-#{index}",
          started_at: (index + 1).minutes.ago,
          run: run,
          workflow: workflow
        )
        run.command_spans.create!(
          job: job,
          workflow: workflow,
          step: step,
          sequence: index + 1,
          name: "rspec #{index}",
          command_excerpt: "bin/rspec",
          started_at: (index + 1).minutes.ago,
          hostname: "worker-#{index}"
        )
      end

      queries = capture_sql { payload_for(job) }

      expect(queries.grep(/FROM [`"]?command_spans[`"]? WHERE [`"]?command_spans[`"]?.[`"]?run_id[`"]? =/i)).to be_empty
      expect(queries.grep(/FROM [`"]?spawned_processes[`"]? WHERE [`"]?spawned_processes[`"]?.[`"]?run_id[`"]? =/i)).to be_empty
    end

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

    it "redacts GitHub credentials from active process and worker health process payloads" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago
      )
      SpawnedProcess.create!(
        kind: "git",
        command: "git fetch https://x-access-token:ghp_jobdetail@github.com/acme/widgets.git",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        started_at: 1.minute.ago,
        run: run,
        workflow: workflow
      )

      payload = payload_for(job)
      serialized = JSON.generate(payload)
      active_process = payload.dig(:workflows, 0, :steps, 0, :runs, 0, :active_process)

      expect(active_process[:command]).to eq("git fetch https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
      expect(serialized).not_to include("ghp_jobdetail")
      expect(serialized).not_to include("x-access-token:ghp_")
    end

    it "omits per-run worker health correlation from the default workflow payload" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", worker_hostname: "worker-1")
      step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "succeeded", details: { "name" => "rspec" })
      Run.create!(
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

      run_payload = payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

      expect(run_payload).not_to have_key(:worker_health_correlation)
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

  describe "#actions_json can_retry_pr_ingestion" do
    def external_pr_job(state: "implemented")
      Job.create!(
        user: user, repository: repo,
        kind: "external_pr", state: "implemented",
        external_pr_number: 55, external_pr_fork: false,
        branch_name: "dependabot/bundler/sqlite3-2.9.4"
      ).tap { |j| j.update_columns(state: state) }
    end

    it "is true when the latest external_pr_ingest workflow failed" do
      job = external_pr_job(state: "failed")
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "failed")

      payload = payload_for(job)

      expect(payload.dig(:actions, :can_retry_pr_ingestion)).to be(true)
      expect(payload.dig(:paths, :app_retry_pr_ingestion_path)).to eq("/api/v1/app/jobs/#{job.id}/retry_pr_ingestion")
    end

    it "is false when the latest external_pr_ingest workflow succeeded" do
      job = external_pr_job
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "succeeded")

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end

    it "is false for a same-repo issue Job even when its latest workflow failed" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      Workflow.create!(job: job, trigger_kind: "initial", state: "failed")

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end

    it "is false while a workflow is already active for the Job" do
      job = external_pr_job(state: "failed")
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "failed")
      Workflow.create!(job: job, trigger_kind: "rebase", state: "running")

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
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

    it "returns the block reason from a running workflow deferred at a phase boundary" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "start_blocked_at" => "2026-08-04T12:00:00Z",
          "start_blocked_details" => {
            "action" => "delay_until",
            "reason" => "worker_host_pressure_high",
            "phase_step_kind" => "grader_fanout"
          }
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("workflow_admission_budget")
      expect(result.dig(:job, :start_blocked_at)).to eq("2026-08-04T12:00:00Z")
      expect(result.dig(:job, :start_blocked_details)).to include(
        "reason" => "worker_host_pressure_high",
        "phase_step_kind" => "grader_fanout"
      )
    end

    it "does not compute a breakdown for non-admission block reasons" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "stack_dependencies_not_ready",
          "start_blocked_at" => "2026-08-04T12:00:00Z"
        }
      )

      expect(payload_for(job).dig(:job, :start_blocked_breakdown)).to be_nil
    end

    it "surfaces a step-profile pressure breakdown with current values vs the recorded thresholds" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "start_blocked_at" => "2026-08-04T12:00:00Z",
          "start_blocked_details" => {
            "action" => "delay_until",
            "reason" => "predicted_budget_pressure_high",
            "pressure" => {
              "projected" => { "cpu_pressure" => 132.4, "io_pressure" => 20.0, "memory_used_percent" => 40.0 },
              "host" => { "telemetry_state" => "present" }
            }
          }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown).to include(
        "reason" => "predicted_budget_pressure_high",
        "category" => "step_profile_pressure",
        "telemetry_state" => "present",
        "telemetry_absent" => false
      )
      expect(breakdown["dimensions"]).to include(
        include("metric" => "cpu_pressure", "current" => 132.4, "threshold" => WorkflowAdmissionBudget::CPU_BUDGET, "over_threshold" => true)
      )
    end

    it "surfaces a hard host pressure breakdown for the exact metric that tripped" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "start_blocked_at" => "2026-08-04T12:00:00Z",
          "start_blocked_details" => {
            "action" => "requires_override",
            "reason" => "worker_memory_exhausted",
            "pressure" => { "host" => { "max_memory_used_percent" => 97.2, "telemetry_state" => "present" } }
          }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown["category"]).to eq("hard_host_pressure")
      expect(breakdown["dimensions"]).to eq(
        [ { "metric" => "memory_used_percent", "label" => "Memory used", "current" => 97.2, "threshold" => WorkflowAdmissionBudget::HARD_MEMORY_USED_PERCENT, "over_threshold" => true } ]
      )
    end

    it "distinguishes the telemetry-absent case in the breakdown" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "start_blocked_at" => "2026-08-04T12:00:00Z",
          "start_blocked_details" => {
            "action" => "delay_until",
            "reason" => "worker_host_pressure_high",
            "pressure" => { "host" => { "telemetry_state" => "absent" } }
          }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown["telemetry_state"]).to eq("absent")
      expect(breakdown["telemetry_absent"]).to be(true)
    end
  end

  describe "resource admission diagnostics visibility" do
    # The `user` let is the first User created in the example, so
    # User#promote_first_user_to_admin makes it an admin. A second user
    # created afterward is a genuine non-admin.
    it "hides the admin diagnostics link for non-admin users" do
      job = Factories.job_record(user: user, repository: repo)
      non_admin = Factories.user

      result = described_class.build(job: job, user: non_admin)
      expect(result.dig(:actions, :can_view_resource_admission_diagnostics)).to be(false)
    end

    it "exposes the admin diagnostics link for admin users" do
      job = Factories.job_record(user: user, repository: repo)

      result = described_class.build(job: job, user: user)
      expect(result.dig(:actions, :can_view_resource_admission_diagnostics)).to be(true)
      expect(result.dig(:paths, :admin_resource_admission_path)).to eq("/admin/resource_admission")
    end
  end

  describe "#typed_artifacts" do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "returns an empty array when no workflow has typed_artifacts" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).fetch(:typed_artifacts)).to eq([])
    end

    it "includes typed artifacts from a workflow's artifacts" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Schema ERD", "payload" => { "tables" => [] }, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first).to include(
        type: "rails_schema_erd",
        title: "Schema ERD",
        payload: { "tables" => [] },
        created_at: "2026-08-06T10:00:00Z",
        renderer_type: nil
      )
    end

    it "annotates artifacts with renderer_type from a registered artifact_renderer plugin" do
      renderer_class = Class.new do
        include Syrus::Plugin::ArtifactRenderer
        def self.artifact_type = "rails_schema_erd"
        def self.renderer_type = :erd_diagram
      end

      Syrus::PluginRegistry.register(
        name: "test_renderer_plugin", version: "1.0.0",
        provides: { artifact_renderer: renderer_class }
      )

      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Schema ERD", "payload" => {}, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.first).to include(renderer_type: "erd_diagram")
    end

    it "deduplicates by type across workflows, keeping the most recent entry" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Old ERD", "payload" => { "version" => 1 }, "created_at" => "2026-08-06T09:00:00Z" }
          ]
        }
      )
      Workflow.create!(
        job: job, trigger_kind: "retry", state: "succeeded",
        created_at: Time.current,
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Updated ERD", "payload" => { "version" => 2 }, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first[:title]).to eq("Updated ERD")
    end

    it "includes artifacts of different types from multiple workflows" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "ERD", "payload" => {}, "created_at" => "2026-08-06T09:00:00Z" },
            { "type" => "rails_migration_diff", "title" => "Diff", "payload" => {}, "created_at" => "2026-08-06T09:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.map { |a| a[:type] }).to contain_exactly("rails_schema_erd", "rails_migration_diff")
    end

    it "skips artifact entries that are not hashes" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: { "typed_artifacts" => [ nil, "bad", { "type" => "ok", "title" => "OK", "payload" => {}, "created_at" => "2026-08-06T10:00:00Z" } ] }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first[:type]).to eq("ok")
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

  describe "#actions_json can_run_visual_review" do
    # Mirrors can_start_preview's approach: read .syrus.yml straight off the
    # local bare clone (no GitHub API call) so job-detail rendering stays
    # cheap. Build a real tiny bare clone under a scratch SYRUS_DATA_ROOT so
    # the git-show code path is exercised rather than stubbed away.
    around do |example|
      @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
      previous_root = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
      example.run
      ENV["SYRUS_DATA_ROOT"] = previous_root
      FileUtils.rm_rf(@data_root)
    end

    def write_bare_clone(repository, syrus_yml: nil)
      work_dir = Dir.mktmpdir("syrus-work")
      system("git", "init", "-q", "-b", "main", work_dir, exception: true)
      system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
      File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
      File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
      system("git", "-C", work_dir, "add", ".", exception: true)
      system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

      clone_path = @data_root.join("clones", "#{repository.id}.git")
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    it "is true for an implemented job when .syrus.yml enables visual_review" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)
    end

    it "is false when .syrus.yml explicitly disables visual_review" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: false\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when .syrus.yml has a visual_review block without an enabled key" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  rounds: 2\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)

      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when .syrus.yml has no visual_review block" do
      write_bare_clone(repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)

      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when there is no local clone yet" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)
    end

    it "is false for a job that is not implemented or approved, even when configured" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "is false for an implemented job with an active run" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      job.runs.create!(trigger_kind: "manual_visual_review", agent_provider: job.agent_provider)

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end
  end
end
