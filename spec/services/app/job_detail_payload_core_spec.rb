require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
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

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
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
    it "does not include hidden worker health correlation in the default job detail payload" do
      job = Factories.job(repository: repo)

      expect(WorkerHealthRunCorrelation).not_to receive(:for_job)
      expect(payload_for(job).fetch(:job)).not_to have_key(:worker_health_correlation)
    end

    it "resolves approval evidence to a grader step workflow link when the Job was auto-approved" do
      job = Factories.job(repository: repo)
      grader_step = job.workflows.first.steps.first
      job.update!(approval_evidence: { "rule" => "if_graders_pass", "source" => "AutoApprovalRule", "grader_step_id" => grader_step.id })

      expect(payload_for(job).dig(:job, :approval_evidence)).to eq(
        rule: "if_graders_pass",
        source: "AutoApprovalRule",
        grader_step_id: grader_step.id,
        grader_step_workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{grader_step.workflow_id}"
      )
    end

    it "omits the grader step workflow link when the grader step no longer exists" do
      job = Factories.job_record(user: user, repository: repo, state: "approved", approval_evidence: { "rule" => "if_graders_pass", "source" => "AutoApprovalRule", "grader_step_id" => 999_999 })

      expect(payload_for(job).dig(:job, :approval_evidence)).to eq(
        rule: "if_graders_pass",
        source: "AutoApprovalRule",
        grader_step_id: 999_999,
        grader_step_workflow_path: nil
      )
    end

    it "returns nil approval evidence when the Job was not auto-approved" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).dig(:job, :approval_evidence)).to be_nil
    end

    it "includes goal provenance when the Job was created from a goal proposal" do
      chat_session = ChatSession.create!(user: user, repository: repo)
      goal = ChatGoal.create!(chat_session: chat_session, user: user, repository: repo, prompt: "Show Job goal provenance")
      job = Factories.job_record(
        user: user,
        repository: repo,
        chat_goal: goal,
        goal_prompt_snapshot: ChatProposal.goal_prompt_snapshot_for(goal)
      )

      expect(payload_for(job).dig(:job, :goal_provenance)).to include(
        chat_goal_id: goal.id,
        prompt_snapshot: include("prompt" => "Show Job goal provenance")
      )
    end

    it "includes cached PR check state and a GitHub checks link" do
      checked_at = Time.zone.parse("2026-08-26T19:20:00Z")
      job = Factories.job_record(
        user: user,
        repository: repo,
        pr_number: 2796,
        pr_checks_state: "failing",
        pr_checks_sha: "3bf7b4593d430ad7c5a75b0fecfe4fe3c34bfc4e",
        pr_checks_checked_at: checked_at
      )

      expect(payload_for(job).dig(:job, :pr_checks)).to eq(
        state: "failing",
        sha: "3bf7b4593d430ad7c5a75b0fecfe4fe3c34bfc4e",
        short_sha: "3bf7b45",
        checked_at: checked_at.iso8601,
        checks_url: "https://github.com/#{repo.owner}/#{repo.name}/pull/2796/checks"
      )
    end

    it "omits PR check details when no cached state exists" do
      job = Factories.job_record(user: user, repository: repo, pr_number: 2796)

      expect(payload_for(job).dig(:job, :pr_checks)).to be_nil
    end

    it "includes a link to the repository's edit settings page" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).dig(:repository, :edit_repository_path)).to eq("/repositories/#{repo.id}/edit")
    end

    it "includes the landing blocker override grant when present" do
      admin = Factories.user
      requested_at = Time.zone.parse("2026-08-10T09:00:00Z")
      job = Factories.job_record(
        user: user,
        repository: repo,
        landing_blocker_override_key: "landing_paused",
        landing_blocker_override_reason: "Verified queue pause was stale.",
        landing_blocker_override_requested_at: requested_at,
        landing_blocker_override_requested_by_user: admin
      )

      expect(payload_for(job).dig(:job, :landing_blocker_override_requested_at)).to eq(requested_at.iso8601)
      expect(payload_for(job).dig(:job, :landing_blocker_override_requested_by)).to eq(
        id: admin.id,
        display_name: admin.display_name,
        email_address: admin.email_address
      )
    end

    it "returns nil landing blocker override fields when no override was ever requested" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).dig(:job, :landing_blocker_override_requested_at)).to be_nil
      expect(payload_for(job).dig(:job, :landing_blocker_override_requested_by)).to be_nil
    end

    it "shows blocked non-landing WorkUnits as paused" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      workflow = Workflow.create!(job: job, trigger_kind: "manual_visual_review", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "manual_visual_review", state: "blocked", blocked_reason: "admission_control")
      next_check = 5.minutes.from_now
      unit.update!(
        blocked_until: next_check,
        blocked_details: { "reason" => "worker_host_pressure_high" }
      )

      payload = payload_for(job).fetch(:job)
      expect(payload[:summary_state]).to eq("paused")
      expect(payload[:start_blocked_reason]).to eq("admission_control")
      expect(payload[:start_blocked_next_check_at]).to eq(next_check.iso8601)
      expect(payload[:start_blocked_details]).to eq("reason" => "worker_host_pressure_high")

      AppSetting.current.update!(show_work_unit_debug: true)
      active_work = payload_for(job).fetch(:active_work)
      expect(active_work).to include(
        kind: "manual_visual_review",
        label: "Manual visual review",
        blocked_reason: "admission_control",
        blocked_label: "Admission control",
        blocked_details: { "reason" => "worker_host_pressure_high" }
      )
    end

    it "shows a blocked WorkUnit with an actively running Run as running" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "blocked", blocked_reason: "resource_safety")
      step = workflow.steps.create!(kind: "grader", position: 1, state: "running")
      step.runs.create!(job: job, user: user, trigger_kind: workflow.trigger_kind, state: "running")

      payload = payload_for(job).fetch(:job)

      expect(payload[:summary_state]).to eq("running")
      expect(payload[:start_blocked_reason]).to eq("resource_safety")
      expect(payload[:any_active_run]).to be true
    end

    it "keeps blocked landing WorkUnits in the landing state" do
      job = Factories.job_record(user: user, repository: repo, state: "landing")
      workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "auto_merge", state: "blocked", blocked_reason: "admission_control")

      expect(payload_for(job).dig(:job, :summary_state)).to eq("landing")
    end

    it "detects historical prepare skip artifacts without a workflow artifact LIKE query" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: { "prepare_skipped_reason" => "issue_label" }
      )
      queries = capture_sql do
        expect(payload_for(job).fetch(:job)).to include(
          prepare_skipped: true,
          prepare_skip_reason: "issue_label"
        )
      end

      expect(queries.grep(/prepare_skipped_reason/)).to be_empty
    end

    it "shows failed jobs with active repair WorkUnits as repairing" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "running")

      payload = payload_for(job).fetch(:job)

      expect(payload).to include(
        state: "failed",
        summary_state: "repairing",
        any_active_run: true
      )
      expect(payload[:active_repair_work]).to include(
        kind: "ci_failure",
        workflow_id: workflow.id,
        workflow_state: "running",
        work_unit_id: unit.id,
        work_unit_state: "running"
      )
    end

    it "does not show stale pause artifacts as paused while a WorkUnit-owned workflow is active" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      owner = Factories.job_record(user: user, repository: repo, state: "running")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "pause_reason" => "workflow_admission_budget",
          "start_blocked_reason" => "workflow_admission_budget"
        }
      )
      owner_workflow = Workflow.create!(job: owner, trigger_kind: "merge_train", state: "running")
      attach_work_unit(owner_workflow, member_jobs: [ owner, job ], kind: "merge_train", state: "running")

      expect(payload_for(job).dig(:job, :summary_state)).to eq("running")
    end

    it "prefers blocked WorkUnit data over stale workflow block artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "start_blocked_reason" => "workflow_admission_budget",
          "start_blocked_details" => { "reason" => "stale_artifact" }
        }
      )
      workflow = Workflow.create!(job: job, trigger_kind: "manual_visual_review", state: "running")
      unit = attach_work_unit(
        workflow,
        member_jobs: [ job ],
        kind: "manual_visual_review",
        state: "blocked",
        blocked_reason: "provider_availability"
      )
      unit.update!(blocked_details: { "provider" => "codex" })

      payload = payload_for(job).fetch(:job)

      expect(payload[:start_blocked_reason]).to eq("provider_availability")
      expect(payload[:start_blocked_details]).to eq("provider" => "codex")
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

  describe "#sccache" do
    it "returns nil when no workflow ever captured an sccache stats snapshot" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded")

      expect(payload_for(job)[:sccache]).to be_nil
    end

    it "returns the latest capture with a normalized stats summary" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "sccache_stats" => [
            {
              "run_id" => 1,
              "step_kind" => "prepare",
              "label" => "cmake --build .",
              "iteration" => 1,
              "captured_at" => "2026-08-20T10:00:00Z",
              "stats" => { "cache_hits" => 5, "cache_misses" => 2, "cache_size" => 104_857_600 }
            },
            {
              "run_id" => 2,
              "step_kind" => "grader",
              "label" => "coverage",
              "iteration" => 2,
              "captured_at" => "2026-08-20T10:05:00Z",
              "stats" => { "cache_hits" => 9, "cache_misses" => 3, "cache_size" => 209_715_200 }
            }
          ]
        }
      )

      expect(payload_for(job)[:sccache]).to eq(
        workflow_id: workflow.id,
        run_id: 2,
        step_kind: "grader",
        label: "coverage",
        iteration: 2,
        captured_at: "2026-08-20T10:05:00Z",
        summary: {
          hits: 9,
          misses: 3,
          hit_rate: 75.0,
          cache_size: 209_715_200,
          max_cache_size: nil,
          cache_location: nil
        }
      )
    end

    it "picks the capture with the latest captured_at across workflows, not the newest workflow" do
      job = Factories.job_record(repository: repo)
      newer_workflow_stale_capture = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: {
          "sccache_stats" => [
            { "run_id" => 3, "step_kind" => "prepare", "label" => "cmake", "iteration" => 1, "captured_at" => "2026-08-20T09:00:00Z", "stats" => { "cache_hits" => 1, "cache_misses" => 1 } }
          ]
        }
      )
      older_workflow_fresh_capture = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: {
          "sccache_stats" => [
            { "run_id" => 4, "step_kind" => "grader", "label" => "coverage", "iteration" => 1, "captured_at" => "2026-08-20T11:00:00Z", "stats" => { "cache_hits" => 8, "cache_misses" => 0 } }
          ]
        }
      )

      expect(payload_for(job)[:sccache]).to include(workflow_id: older_workflow_fresh_capture.id)
      expect(payload_for(job)[:sccache][:workflow_id]).not_to eq(newer_workflow_stale_capture.id)
    end

    it "returns nil-valued summary fields when the raw stats hash is unrecognizable" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "sccache_stats" => [
            { "run_id" => 1, "step_kind" => "prepare", "label" => "cmake", "iteration" => 1, "captured_at" => "2026-08-20T10:00:00Z", "stats" => "sccache: error: server startup failed" }
          ]
        }
      )

      expect(payload_for(job)[:sccache][:summary]).to eq(
        hits: nil, misses: nil, hit_rate: nil, cache_size: nil, max_cache_size: nil, cache_location: nil
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

    it "uses the latest run summary without inheriting the ascending job runs order" do
      job = Factories.job(repository: repo)
      job.initial_run.update!(
        agent_summary: "Older run summary.",
        created_at: 2.hours.ago,
        finished_at: 2.hours.ago
      )
      workflow = Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded")
      step = Step.create!(workflow: workflow, kind: "respond", position: 0, state: "succeeded")
      latest_run = step.runs.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        agent_summary: "Latest run summary.",
        created_at: 1.hour.ago,
        finished_at: 1.hour.ago
      )

      expect(payload_for(job)[:summary]).to include(
        run_id: latest_run.id,
        text: "Latest run summary."
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
end
