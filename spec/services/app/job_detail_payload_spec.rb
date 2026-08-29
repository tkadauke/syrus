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

    it "includes goal provenance from the Job record" do
      chat = ChatSession.create!(user: user, repository: repo)
      goal = chat.chat_goals.create!(prompt: "Build traceable work.", auto_file_proposals: true)
      snapshot = ChatGoalProvenance.snapshot(goal)
      job = Factories.job_record(
        user: user,
        repository: repo,
        kind: "direct",
        issue_number: nil,
        issue_title: "Trace work",
        chat_goal: goal,
        goal_prompt_snapshot: snapshot
      )

      expect(payload_for(job).dig(:job, :goal_provenance)).to include(
        chat_goal_id: goal.id,
        prompt_snapshot: include("prompt" => "Build traceable work.")
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

  describe "#workflows_json" do
    before do
      AppSetting.current.update!(show_work_unit_debug: true)
    end

    it "includes the active work intent in the default job detail payload" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: unit.work_intent_id,
        kind: "initial",
        label: "Initial implementation",
        state: "requested",
        scope_type: "job",
        scope_id: job.id,
        execution_label: nil,
        execution_status: "running"
      )
    end

    it "includes the blocked WorkUnit reason as the intent execution label" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "queued")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "blocked", blocked_reason: "admission_control")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: unit.work_intent_id,
        execution_status: "blocked",
        execution_label: "Admission control"
      )
    end

    it "prefers running WorkUnit attempts over newer blocked attempts in the active work card" do
      job = Factories.job_record(user: user, repository: repo)
      running_workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running", created_at: 5.minutes.ago)
      running_unit = attach_work_unit(running_workflow, member_jobs: [ job ], kind: "ci_failure", state: "running")
      blocked_workflow = Workflow.create!(job: job, trigger_kind: "rebase", state: "queued")
      blocked_unit = attach_work_unit(blocked_workflow, member_jobs: [ job ], kind: "rebase", state: "blocked", blocked_reason: "resource_safety")

      payload = payload_for(job)

      expect(payload.fetch(:active_work)).to include(
        id: running_unit.id,
        kind: "ci_failure",
        state: "running",
        workflow_id: running_workflow.id
      )
      expect(workflows_payload_for(job).fetch(:work_units).map { |unit| unit[:id] }).to include(blocked_unit.id)
    end

    it "includes a waiting job-scoped intent even when no work unit exists yet" do
      job = Factories.job_record(user: user, repository: repo)
      intent = WorkIntent.create!(
        kind: "initial",
        state: "waiting",
        repository: repo,
        scope_type: "job",
        scope_id: job.id,
        actor: user,
        wait_reason: "dependency",
        wait_details: { "blocked_by_job_ids" => [ 9 ] },
        source_type: "spec"
      )

      payload = payload_for(job)

      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "initial",
        label: "Initial implementation",
        state: "waiting",
        wait_reason: "dependency",
        wait_label: "Dependency",
        wait_details: include("blocked_by_job_ids" => [ 9 ]),
        execution_status: "blocked"
      )

      workflows_payload = workflows_payload_for(job)

      expect(workflows_payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "initial",
        label: "Initial implementation",
        state: "waiting",
        wait_reason: "dependency",
        wait_label: "Dependency",
        wait_details: include("blocked_by_job_ids" => [ 9 ]),
        execution_status: "blocked"
      )
    end

    it "does not present stale work-unit debug state as current work after a job closes" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "failed")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "failed")
      WorkIntent.create!(
        kind: "ci_failure",
        state: "requested",
        repository: repo,
        scope_type: "job",
        scope_id: job.id,
        actor: user,
        source_type: "spec"
      )
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

      payload = payload_for(job)
      workflows_payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to be_nil
      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:work_units)).to be_empty
      expect(workflows_payload.fetch(:current_intent)).to be_nil
      expect(workflows_payload.fetch(:work_units)).to be_empty
    end

    it "does not present active-looking WorkUnit state as current work after a job closes" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "blocked", blocked_reason: "admission_control")
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

      payload = payload_for(job)

      expect(payload.dig(:job, :summary_state)).to eq("closed")
      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:work_units)).to be_empty
    end

    it "includes a waiting epic-scoped intent for member jobs before a work unit exists" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, epic: epic)
      intent = WorkIntent.create!(
        kind: "merge_train",
        state: "waiting",
        repository: repo,
        scope_type: "epic",
        scope_id: epic.id,
        actor: user,
        wait_reason: "epic_not_ready",
        wait_details: { "pending_job_ids" => [ job.id ] },
        source_type: "spec"
      )

      payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "merge_train",
        label: "Epic merge-train",
        state: "waiting",
        scope_type: "epic",
        scope_id: epic.id,
        wait_reason: "epic_not_ready",
        wait_label: "Epic not ready",
        wait_details: include("pending_job_ids" => [ job.id ]),
        execution_status: "blocked"
      )
    end

    it "includes work units involving the job even when the workflow is attached to another job" do
      epic = Factories.epic(user: user, repository: repo)
      first = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 101)
      second = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 102)
      workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ first, second ], kind: "merge_train")

      payload = workflows_payload_for(second)

      expect(payload.fetch(:workflows)).to be_empty
      expect(payload.fetch(:work_units)).to contain_exactly(
        include(
          id: unit.id,
          kind: "merge_train",
          label: "Epic merge-train",
          state: "running",
          workflow_id: workflow.id,
          workflow_trigger_kind: "merge_train",
          workflow_state: "running",
          workflow_attached_job_id: first.id,
          member_role: "member",
          scope_type: "epic",
          scope_id: epic.id,
          workflow: nil
        )
      )
    end

    it "labels bundle-backed merge train landing steps as job bundle landings" do
      first = Factories.job_record(user: user, repository: repo, issue_number: 101)
      second = Factories.job_record(user: user, repository: repo, issue_number: 102)
      workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
      Step.create!(workflow: workflow, kind: "merge_train_land", position: 1)
      Step.create!(workflow: workflow, kind: "merge_train_land_after_rebase", position: 2)
      attach_work_unit(workflow, member_jobs: [ first, second ], kind: "job_bundle")

      workflow_payload = workflows_payload_for(first).fetch(:workflows).first
      names_by_kind = workflow_payload.fetch(:steps).to_h { |step| [ step.fetch(:kind), step.fetch(:display_name) ] }

      expect(names_by_kind).to include(
        "merge_train_land" => "Land job bundle",
        "merge_train_land_after_rebase" => "Land job bundle after rebase"
      )
    end

    it "keeps Epic wording for Epic merge train landing steps" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 101)
      workflow = Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")
      Step.create!(workflow: workflow, kind: "merge_train_land", position: 1)
      attach_work_unit(workflow, member_jobs: [ job ], kind: "merge_train")

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first
      expect(workflow_payload.fetch(:steps).first.fetch(:display_name)).to eq("Land Epic")
    end

    it "includes parent and preemption relationships for active WorkUnit diagnostics" do
      parent_workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
      parent = attach_work_unit(parent_workflow, member_jobs: [ job ], kind: "auto_merge")
      child_job = Factories.job_record(user: user, repository: repo, issue_number: 102)
      child_workflow = Workflow.create!(job: child_job, trigger_kind: "landing_validation", state: "queued")
      child = attach_work_unit(child_workflow, member_jobs: [ child_job ], kind: "landing_validation", state: "blocked")
      child.update!(
        parent_work_unit: parent,
        preemption_reason: "terminal_parent_work_unit",
        preempted_by_work_unit: parent
      )

      payload = workflows_payload_for(child_job)

      expect(payload.fetch(:work_units)).to contain_exactly(
        include(
          id: child.id,
          parent_work_unit_id: parent.id,
          parent_work_unit_kind: "auto_merge",
          parent_work_unit_label: "Auto-merge",
          preemption_reason: "terminal_parent_work_unit",
          preempted_by_work_unit_id: parent.id,
          preempted_by_work_unit_kind: "auto_merge",
          preempted_by_work_unit_label: "Auto-merge"
        )
      )
    end

    it "renders WorkUnit-owned direct workflows in the regular workflow list without nesting them under WorkUnits" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )
      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        severity: "low",
        title: "needs attention"
      )
      SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: "/tmp/repo",
        hostname: "worker-1",
        pid: 4321,
        started_at: 1.minute.ago,
        run: run,
        workflow: workflow
      )
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = workflows_payload_for(job)
      workflow_payload = payload.fetch(:workflows).first
      nested_step = workflow_payload.fetch(:steps).first
      nested_run = nested_step.fetch(:runs).first

      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
      expect(payload.fetch(:work_units).map { |unit| unit[:workflow] }).to eq([ nil ])
      expect(payload.fetch(:workflows_pagination)).to include(
        total_workflows: 1,
        total_pages: 1,
        first_item: 1,
        last_item: 1
      )
      expect(workflow_payload.fetch(:steps).map { |entry| entry[:kind] }).to include("implement")
      expect(nested_step.fetch(:warnings)).to include(include(kind: "grader_side_effect", title: "needs attention"))
      expect(nested_run).to include(id: run.id, state: "running", can_stop: true)
      expect(nested_run.fetch(:active_process)).to include(
        kind: "agent",
        command: "claude --print",
        hostname: "worker-1",
        pid: 4321
      )
    end

    it "omits historical terminal WorkUnits from the job detail debug panel" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "failed")
      Step.create!(workflow: workflow, kind: "analyze_and_fix", position: 1, state: "failed")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "failed")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
      expect(payload.fetch(:work_units)).to be_empty
    end

    it "keeps WorkUnit workflow graphs out of the default job detail response" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = payload_for(job)

      expect(payload.dig(:active_work, :workflow)).to be_nil
      expect(payload.dig(:work_units, 0, :workflow)).to be_nil
    end

    it "does not call the legacy workflow navigation helper while building the job detail shell" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      expect(App::WorkflowNavigation).not_to receive(:path)

      payload = payload_for(job)

      expect(payload.dig(:workflows_pagination, :total_workflows)).to eq(1)
    end

    it "renders step state from the latest run projection while preserving drift diagnostics" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "queued")
      Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )

      payload = workflows_payload_for(job)
      step_payload = payload.fetch(:workflows).first.fetch(:steps).first

      expect(step_payload).to include(
        kind: "implement",
        state: "running",
        persisted_state: "queued",
        display_status: "running"
      )
    end

    it "keeps legacy workflows without WorkUnit ownership in the fallback workflow list" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:work_units)).to be_empty
      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
    end

    it "keeps terminal WorkUnit-owned workflows in the regular paginated workflow list without duplicating them as attempts" do
      job = Factories.job_record(user: user, repository: repo)
      51.times do |index|
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", created_at: index.minutes.ago)
        Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
        attach_work_unit(workflow, member_jobs: [ job ], kind: "initial", state: "succeeded")
      end

      payload = workflows_payload_for(job)

      expect(payload.fetch(:work_units)).to be_empty
      expect(payload.fetch(:workflows).size).to eq(App::WorkflowNavigation::PER_PAGE)
      expect(payload.fetch(:workflows_pagination)).to include(total_workflows: 51)
    end

    it "includes generic WorkflowWarning rows on the owning step, redacted" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      step = Step.create!(workflow: workflow, kind: "grader", position: 1)
      pending_warning = WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        severity: "medium",
        title: "leaked https://x-access-token:abc123@github.com/acme/widgets.git",
        evidence: { "command" => "curl https://x-access-token:abc123@github.com/acme/widgets.git" },
        suggested_prompt: "fix it"
      )
      dismissed_warning = WorkflowWarnings.record!(workflow: workflow, step: step, kind: "grader_side_effect", title: "already handled")
      dismissed_warning.dismiss!

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first
      step_payload = workflow_payload.fetch(:steps).first
      warnings_by_id = step_payload[:warnings].index_by { |w| w[:id] }

      expect(step_payload[:warnings].size).to eq(2)
      expect(warnings_by_id[pending_warning.id]).to include(
        kind: "grader_side_effect",
        severity: "medium",
        state: "pending",
        created_job_id: nil
      )
      expect(warnings_by_id[pending_warning.id][:title]).not_to include("abc123")
      expect(warnings_by_id[pending_warning.id][:evidence]["command"]).not_to include("abc123")
      expect(warnings_by_id[dismissed_warning.id][:state]).to eq("dismissed")
    end

    it "bounds serialized steps per workflow and keeps workflow failure classification" do
      stub_const("App::JobDetailPayload::WorkflowSerializers::MAX_STEPS_PER_WORKFLOW", 3)
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")

      5.times do |index|
        state = index.zero? ? "failed" : "succeeded"
        step = Step.create!(
          workflow: workflow,
          kind: "grader",
          position: index + 1,
          state: state,
          finished_at: (5 - index).minutes.ago
        )
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: state,
          finished_at: (5 - index).minutes.ago
        )
        next unless index.zero?

        RunFailureClassification.create!(
          run: run,
          classification: "grader_failure",
          retryable: true,
          confidence: 0.9,
          reason: "rspec failed",
          classified_at: Time.current
        )
      end

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first

      expect(workflow_payload).to include(
        steps_total: 5,
        steps_displayed: 3,
        steps_truncated: true
      )
      expect(workflow_payload.fetch(:steps).map { |step| step[:position] }).to eq([ 3, 4, 5 ])
      expect(workflow_payload.dig(:failure_classification, :classification)).to eq("grader_failure")
    end

    it "bounds serialized run history per step while preserving active runs" do
      stub_const("App::JobDetailPayload::WorkflowSerializers::MAX_RUNS_PER_STEP", 2)
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "running")

      active_run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        created_at: 10.minutes.ago,
        started_at: 10.minutes.ago
      )
      Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 8.minutes.ago, finished_at: 8.minutes.ago)
      Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 6.minutes.ago, finished_at: 6.minutes.ago)
      recent_succeeded = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "succeeded", created_at: 2.minutes.ago, finished_at: 2.minutes.ago)
      recent_failed = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 1.minute.ago, finished_at: 1.minute.ago)

      step_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0)

      expect(step_payload).to include(
        runs_total: 5,
        runs_displayed: 3,
        runs_truncated: true
      )
      expect(step_payload.fetch(:runs).map { |run| run[:id] }).to eq([ active_run.id, recent_succeeded.id, recent_failed.id ])
    end

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

    it "does not load full run diff text for workflow rows" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
      Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        agent_diff: "a" * 1024,
        step_agent_diff: "b" * 2048
      )

      queries = []
      payload = nil
      callback = lambda do |_name, _started, _finished, _id, sql_payload|
        next if sql_payload[:cached] || sql_payload[:name] == "SCHEMA"

        queries << sql_payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        payload = workflows_payload_for(job)
      end

      run_payload = payload.dig(:workflows, 0, :steps, 0, :runs, 0)
      expect(run_payload).to include(
        agent_diff_present: true,
        agent_diff_bytes: 1024,
        step_agent_diff_present: true,
        step_agent_diff_bytes: 2048
      )

      run_selects = queries.select { |sql| sql.match?(/FROM [`"]?runs[`"]?/i) }
      expect(run_selects.grep(/SELECT\s+[`"]?runs[`"]?\.\*/i)).to be_empty
    end

    it "loads workflow failure classifications in bulk" do
      job = Factories.job_record(repository: repo)

      3.times do |index|
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed", created_at: (3 - index).minutes.ago)
        step = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "failed")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: (3 - index).minutes.ago
        )
        RunFailureClassification.create!(
          run: run,
          classification: "grader_failure",
          retryable: true,
          confidence: 0.9,
          reason: "rspec failed #{index}",
          classified_at: Time.current
        )
      end

      queries = capture_sql { workflows_payload_for(job) }

      per_workflow_failed_run_queries = queries.grep(/FROM [`"]?runs[`"]?.*WHERE .*[`"]?steps[`"]?\.[`"]?workflow_id[`"]? =/im)
      expect(per_workflow_failed_run_queries).to be_empty
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

      active_process = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0, :active_process)

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

      payload = workflows_payload_for(job)
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

      run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

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

      artifacts = workflows_payload_for(job).dig(:workflows, 0, :artifacts)

      expect(artifacts).to include("summary" => "Done")
      expect(artifacts).not_to have_key("iterations")
      expect(artifacts.dig("coverage", "summary")).to eq("lines_pct" => 90.0)
      expect(artifacts["coverage"]).not_to have_key("diff_annotations")
      expect(artifacts["coverage"]).not_to have_key("pr_comment_body")
    end

    describe "run can_resume" do
      def failed_run_with_session(job, workflow)
        step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "failed")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: 5.minutes.ago
        )
        ProviderSession.create!(
          resumable: run,
          provider: "claude",
          session_id: "claude-thread",
          transcript_jsonl: "{}\n"
        )
        run
      end

      it "is true for a failed run with a captured session when no other run is active" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(true)
      end

      it "is false once a newer run on the same Job is queued or running" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)
        job.runs.create!(trigger_kind: "manual", state: "running", started_at: Time.current)

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end

      it "is false while a WorkUnit-owned workflow is active for the Job" do
        job = Factories.job_record(repository: repo)
        owner = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)
        owner_workflow = Workflow.create!(job: owner, trigger_kind: "merge_train", state: "running")
        attach_work_unit(owner_workflow, member_jobs: [ owner, job ], kind: "merge_train", state: "running")

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end

      it "is false without a captured session even when nothing else is active" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "failed")
        Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: 5.minutes.ago
        )

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end
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
          {
            kind: "chat_feedback",
            body: "Old feedback",
            created_at: older.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil,
            workflow_id: older.id,
            workflow_slug: older.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{older.id}"
          },
          {
            kind: "chat_feedback",
            body: "New feedback",
            created_at: newer.created_at.iso8601,
            state: "running",
            feedback_source: nil,
            workflow_id: newer.id,
            workflow_slug: newer.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{newer.id}"
          }
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
            feedback_source: nil,
            workflow_id: workflow.id,
            workflow_slug: workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}"
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
          {
            kind: "chat_feedback",
            body: "Chat feedback",
            created_at: chat_workflow.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil,
            workflow_id: chat_workflow.id,
            workflow_slug: chat_workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{chat_workflow.id}"
          },
          {
            kind: "pr_comment",
            body: "@reviewer: PR feedback",
            created_at: pr_workflow.created_at.iso8601,
            state: "running",
            feedback_source: nil,
            workflow_id: pr_workflow.id,
            workflow_slug: pr_workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{pr_workflow.id}"
          }
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
      WorkUnits::Launcher.instantiate(kind: "rebase", job: job).tap do |workflow|
        workflow.update!(state: "running")
        workflow.work_unit.update!(state: "running")
      end

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end
  end

  describe "#actions_json can_restart" do
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

    it "is false for a queued issue job with no active runs (not yet a last resort)" do
      job = Factories.job_record(repository: repo, issue_number: 5)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
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

    it "is false for a direct job with no active runs (not yet a last resort)" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: "Fix it")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a no_change_needed job" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a failed job with a non-retryable failed step and a reclaimed workspace" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")
      workflow.update_columns(cleaned_up_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a failed job with an available implementation retry" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "implement")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a failed job with an available failed-step retry" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a failed landing attempt with a landing_failure_reason even when no retry action is available" do
      job = Factories.job_record(user: user, repository: repo, state: "failed",
                                 landing_failure_reason: "merge train record not found")
      workflow = create_failed_workflow(job, trigger_kind: "merge_train", failed_step_kind: "merge_train_build")
      workflow.update_columns(cleaned_up_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for an in-progress landing failure where Reapprove/Retry-failed-step still applies" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented",
                                 landing_failure_reason: "auto_merge: required grader failed")
      create_failed_workflow(job, trigger_kind: "auto_merge", failed_step_kind: "auto_merge")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a closed infrastructure (main_grader) job" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      Workflow.create!(job: infra_job, trigger_kind: "main_grader", user: user, state: "succeeded")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      expect(payload_for(infra_job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a closed non-infrastructure job (Reopen is available instead)" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")

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

    def blocked_workflow_for(job:, reason:, details:, state: "queued", blocked_until: nil)
      workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
      workflow.update!(state: state)
      workflow.work_unit.block!(
        reason: reason,
        blocked_until: blocked_until,
        details: details
      )
      workflow
    end

    it "returns the block reason from the queued workflow's WorkUnit state" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "stack_fan_in_base_unavailable",
        details: {
          "kind" => "fan_in_base_unavailable",
          "message" => "multiple dependency branches are ready",
          "dependencies" => [ { "slug" => "JOB-1574" } ]
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("stack_fan_in_base_unavailable")
      expect(result.dig(:job, :start_blocked_at)).to be_present
      expect(result.dig(:job, :start_blocked_details)).to include(
        "kind" => "fan_in_base_unavailable",
        "message" => "multiple dependency branches are ready",
        "dependencies" => [ { "slug" => "JOB-1574" } ]
      )
    end

    it "returns the block reason from a running workflow deferred at a phase boundary" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_workflow_for(
        job: job,
        state: "running",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "worker_host_pressure_high",
          "phase_step_kind" => "grader_fanout"
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("workflow_admission_budget")
      expect(result.dig(:job, :start_blocked_at)).to be_present
      expect(result.dig(:job, :start_blocked_details)).to include(
        "reason" => "worker_host_pressure_high",
        "phase_step_kind" => "grader_fanout"
      )
    end

    it "does not compute a breakdown for non-admission block reasons" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "stack_dependencies_not_ready",
        details: { "start_blocked_reason" => "stack_dependencies_not_ready" }
      )

      expect(payload_for(job).dig(:job, :start_blocked_breakdown)).to be_nil
    end

    it "surfaces a step-profile pressure breakdown with current values vs the recorded thresholds" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "predicted_budget_pressure_high",
          "pressure" => {
            "projected" => { "cpu_pressure" => 132.4, "io_pressure" => 20.0, "memory_used_percent" => 40.0 },
            "host" => { "telemetry_state" => "present" }
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
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "requires_override",
          "reason" => "worker_memory_exhausted",
          "pressure" => { "host" => { "max_memory_used_percent" => 97.2, "telemetry_state" => "present" } }
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
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "worker_host_pressure_high",
          "pressure" => { "host" => { "telemetry_state" => "absent" } }
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

  describe "#actions_json can_request_changes" do
    around do |example|
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      example.run
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end

    it "is true for an implemented job" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is true for an approved-but-not-yet-landed job" do
      job = Factories.job_record(user: user, repository: repo, state: "approved", approved_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is true for an already-closed/merged job" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is false for a job still running" do
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false for a legacy simple-mode Epic child job" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented", epic: epic)

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false for a job closed for an unsuccessful reason" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "invalidated")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false outside simple mode even for an implemented standalone job" do
      AppSetting.current.update!(mode: "advanced")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end
  end

  describe "#actions_json can_deploy and #deploy" do
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

    it "is true for an implemented job when .syrus.yml configures deploy" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(true)
    end

    it "is false when .syrus.yml has no deploy block" do
      write_bare_clone(repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(false)
    end

    it "is false for a job that has not been implemented yet, even when configured" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(false)
    end

    it "is true for a closed job that landed, when configured" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "closed", landed_sha: "abc123")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(true)
    end

    it "includes the latest deploy workflow's status" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      Workflow.create!(job: job, trigger_kind: "deploy", state: "succeeded", finished_at: 1.hour.ago)
      latest = Workflow.create!(job: job, trigger_kind: "deploy", state: "running", started_at: Time.current)

      deploy = payload_for(job).fetch(:deploy)

      expect(deploy).to include(id: latest.id, state: "running")
    end

    it "is nil when no deploy workflow exists" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).fetch(:deploy)).to be_nil
    end
  end

  describe "#delivery_status" do
    it "exposes the job's derived apparent delivery status" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      expect(payload_for(job).dig(:job, :delivery_status)).to eq(:approved_for_local_landing)
    end
  end

  describe "delivery track, PR links, and send_job_upstream" do
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

    def upstream_export_syrus_yml
      <<~YAML
        delivery:
          upstream_export:
            enabled: true
          ref_movement_actions:
            send_job_upstream:
              enabled: true
              source: { kind: job_branch }
              target: { kind: upstream_intake }
              mode: manual_pr
      YAML
    end

    it "defaults delivery_track and delivery_target_ref for a repository with no delivery config" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      payload = payload_for(job).fetch(:job)

      expect(payload[:delivery_track]).to eq("default")
      expect(payload[:delivery_target_ref]).to eq(repo.default_branch)
    end

    it "exposes pr_links for the job, one entry per role" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_LOCAL,
        source_repository_id: repo.id,
        source_ref: "syrus/issue-1",
        target_repository_id: repo.id,
        target_ref: "main",
        pr_number: 42
      )

      pr_links = payload_for(job).fetch(:pr_links)

      expect(pr_links).to contain_exactly(
        include(
          role: "local",
          source_ref: "syrus/issue-1",
          target_ref: "main",
          pr_number: 42,
          pr_url: "https://github.com/#{repo.owner}/#{repo.name}/pull/42"
        )
      )
    end

    it "reports can_send_job_upstream as false with no blocked reason when the repository hasn't configured the action" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(false)
      expect(actions[:send_job_upstream_blocked_reason]).to be_nil
    end

    it "reports can_send_job_upstream as true once send_job_upstream is configured and the job is eligible" do
      canonical = Factories.repository(user: user, default_branch: "main")
      fork_repo = Factories.repository(user: user, default_branch: "main", upstream_repository: canonical)
      write_bare_clone(fork_repo, syrus_yml: upstream_export_syrus_yml)
      job = Factories.job_record(user: user, repository: fork_repo, state: "approved", branch_name: "syrus/issue-9")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(true)
      expect(actions[:send_job_upstream_blocked_reason]).to be_nil
    end

    it "surfaces the blocked reason when send_job_upstream is configured but the job isn't eligible" do
      canonical = Factories.repository(user: user, default_branch: "main")
      fork_repo = Factories.repository(user: user, default_branch: "main", upstream_repository: canonical)
      write_bare_clone(fork_repo, syrus_yml: upstream_export_syrus_yml)
      job = Factories.job_record(user: user, repository: fork_repo, state: "approved", branch_name: nil)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(false)
      expect(actions[:send_job_upstream_blocked_reason]).to include("no branch")
    end
  end
end
