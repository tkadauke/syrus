require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload, :ci_only do
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

  describe ".timeline" do
    it "resolves referenced workflow links without loading the full workflow history again" do
      job = Factories.job_record(user: user, repository: repo)
      workflows = 26.times.map do |index|
        Workflow.create!(
          job: job,
          user: user,
          trigger_kind: "retry",
          state: "succeeded",
          created_at: Time.zone.parse("2026-09-01 12:00:00") + index.minutes
        )
      end
      referenced_workflow = workflows.first
      event = Jobs::Timeline::Event.new(
        at: Time.current,
        kind: :info,
        source: "workflow",
        transition_source: nil,
        title: "#{referenced_workflow.slug} created",
        detail: nil,
        ref: { workflow_id: referenced_workflow.id }
      )
      allow(Jobs::Timeline).to receive(:for).with(job).and_return([ event ])

      queries = capture_sql { @payload = described_class.timeline(job: job) }

      expect(@payload.fetch(:events).first).to include(
        ref_label: referenced_workflow.slug,
        workflow_path: "/jobs/#{job.id}?tab=workflows&workflows_page=3#workflow-#{referenced_workflow.id}"
      )
      expect(queries.grep(/SELECT ["`]?workflows["`]?\.\* FROM ["`]?workflows["`]? WHERE ["`]?workflows["`]?\.["`]?job_id["`]? =/i)).to be_empty
      expect(queries.grep(/SELECT ["`]?workflows["`]?\.["`]?id["`]? FROM ["`]?workflows["`]? WHERE ["`]?workflows["`]?\.["`]?job_id["`]? = .*ORDER BY ["`]?workflows["`]?\.["`]?created_at["`]? DESC/i)).to be_empty
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

    it "loads billed run count and total cost with one aggregate query" do
      job = Factories.job_with_run(repository: repo, run_attrs: { state: "succeeded", cost_usd: BigDecimal("0.12") })
      workflow = job.workflows.first
      paid_step = workflow.steps.create!(kind: "grader", position: 2, state: "succeeded")
      unpaid_step = workflow.steps.create!(kind: "summarize", position: 3, state: "succeeded")
      Run.create!(job: job, step: paid_step, trigger_kind: "initial", state: "succeeded", cost_usd: BigDecimal("0.34"))
      Run.create!(job: job, step: unpaid_step, trigger_kind: "initial", state: "succeeded", cost_usd: nil)

      queries = capture_sql { @payload = payload_for(job) }

      expect(@payload.dig(:job, :total_cost_usd)).to eq(0.46)
      expect(@payload.dig(:job, :billed_runs_count)).to eq(2)
      cost_queries = queries.grep(/FROM ["`]?runs["`]?/i).grep(/cost_usd/i)
      expect(cost_queries.size).to eq(1)
      expect(cost_queries.first).to match(/COUNT\(\*\).*SUM\(cost_usd\)|SUM\(cost_usd\).*COUNT\(\*\)/i)
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
        trigger_kind: "retry",
        state: "succeeded",
        artifacts: { "summary" => "Older workflow without no-PR metadata" },
        created_at: 2.hours.ago
      )
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

      queries = capture_sql { @payload = payload_for(job) }

      expect(@payload.dig(:job, :no_pr_reason)).to include(
        "kind" => "no_effective_changes",
        "message" => "No PR was opened because the workflow made no effective changes.",
        "base_branch" => "syrus/direct-parent"
      )
      artifact_queries = queries.grep(/FROM ["`]?workflows["`]?.*["`]?artifacts["`]?/im)
      expect(artifact_queries).not_to be_empty
      expect(artifact_queries).to all(match(/WHERE/i))
      expect(artifact_queries.grep(/artifacts LIKE/im)).to be_empty
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

    it "reuses the source chat payload for origin chat" do
      chat = ChatSession.create!(user: user, repository: repo)
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)
      epic_proposal = chat.proposals.create!(
        slug: "auth",
        title: "Auth",
        body: "Group auth work.",
        kind: "epic",
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      direct_proposal = chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      chat.messages.create!(role: "assistant", proposal: epic_proposal, content: { "text" => "Epic proposed." })
      direct_message = chat.messages.create!(role: "assistant", proposal: direct_proposal, content: { "text" => "Proposal proposed." })

      queries = capture_sql { @payload = payload_for(job) }

      expect(@payload[:origin_chat]).to eq(
        chat_session_id: chat.id,
        message_id: direct_message.id
      )
      expect(@payload.dig(:job, :source_chat)).to include(
        chat_id: chat.id,
        message_id: direct_message.id
      )
      expect(queries.grep(/FROM ["`]?chat_proposals["`]?/i).size).to eq(1)
      message_query = queries.grep(/FROM ["`]?chat_messages["`]?/i).find { |sql| sql.match?(/ORDER BY/i) }
      expect(message_query).to match(/SELECT ["`]?chat_messages["`]?\./i)
      expect(message_query).not_to match(/SELECT\s+["`]?chat_messages["`]?\.\*/i)
    end
  end

  describe "#discussion_chat_json" do
    it "returns nil when no chat has been attached (the 'Chat about this' link is offered instead)" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).dig(:job, :discussion_chat)).to be_nil
    end

    it "returns the chat permanently linked via 'Chat about this'" do
      job = Factories.job_record(user: user, repository: repo)
      chat = ChatSession.create!(user: user, repository: repo, title: "Bug triage")
      job.chat_attachments.create!(chat_session: chat)

      expect(payload_for(job).dig(:job, :discussion_chat)).to eq(
        chat_id: chat.id,
        chat_title: "Bug triage",
        path: "/chats/#{chat.id}"
      )
    end

    it "is independent from the proposal-based source/origin chat" do
      proposal_chat = ChatSession.create!(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      proposal_chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      discussion_chat = ChatSession.create!(user: user, repository: repo)
      job.chat_attachments.create!(chat_session: discussion_chat)

      payload = payload_for(job)

      expect(payload.dig(:job, :source_chat, :chat_id)).to eq(proposal_chat.id)
      expect(payload.dig(:job, :discussion_chat, :chat_id)).to eq(discussion_chat.id)
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

    it "loads artifact-bearing workflow blobs once when building the detail payload" do
      job = Factories.job_record(repository: repo)
      10.times do |index|
        Workflow.create!(
          job: job,
          trigger_kind: "retry",
          state: "failed",
          created_at: (20 - index).minutes.ago,
          artifacts: {
            "large_irrelevant_blob" => "x" * 10_000,
            "index" => index
          }
        )
      end
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: { "test_plan" => { "steps" => [ "Run bin/rspec" ] } }
      )

      queries = capture_sql { expect(payload_for(job)[:test_plan]).to include(steps: [ "Run bin/rspec" ]) }
      artifact_selects = queries.select do |sql|
        sql.match?(/SELECT .*[`"]?workflows[`"]?\.[`"]?artifacts[`"]?/im) &&
          sql.match?(/FROM [`"]?workflows[`"]?/i)
      end

      expect(artifact_selects.size).to eq(1)
      expect(artifact_selects).to all(match(/WHERE/i))
      expect(artifact_selects).to all(match(/NOT/i))
      expect(artifact_selects).to all(satisfy { |sql| !sql.match?(/artifacts[`"]? LIKE/i) })
    end

    it "builds feedback history without key-specific artifact scans" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        artifacts: { "chat_feedback" => "Please preserve local mode state." }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "Nit: clarify the message." } ] }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "failed",
        artifacts: { "large_irrelevant_blob" => "x" * 10_000 }
      )

      queries = capture_sql do
        history = payload_for(job).fetch(:feedback_history)
        expect(history.map { |entry| entry[:kind] }).to eq(%w[chat_feedback pr_comment])
      end

      artifact_selects = queries.select do |sql|
        sql.match?(/SELECT .*[`"]?workflows[`"]?\.[`"]?artifacts[`"]?/im) &&
          sql.match?(/FROM [`"]?workflows[`"]?/i)
      end
      expect(artifact_selects.size).to eq(1)
      expect(artifact_selects).to all(satisfy { |sql| !sql.match?(/artifacts[`"]? LIKE/i) })
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


  describe "#preview_env_json" do
    it "returns the newest active preview before newer terminal previews without CASE ordering" do
      job = Factories.job(user: user, repository: repo)
      PreviewEnvironment.create!(
        job: job,
        state: "failed",
        port: 20_100,
        internal_host: "127.0.0.1",
        workspace_path: "/tmp/preview-failed",
        error_message: "boot failed",
        created_at: 5.minutes.ago
      )
      active = PreviewEnvironment.create!(
        job: job,
        state: "running",
        port: 20_101,
        internal_host: "127.0.0.1",
        workspace_path: "/tmp/preview-running",
        expires_at: 5.minutes.from_now,
        created_at: 10.minutes.ago
      )

      queries = capture_sql { @payload = payload_for(job) }
      preview_queries = queries.grep(/FROM ["`]?preview_environments["`]?/i)

      expect(@payload[:preview]).to include(
        id: active.id,
        state: "running"
      )
      expect(preview_queries).not_to be_empty
      expect(preview_queries).to all(satisfy { |sql| !sql.match?(/CASE WHEN/i) })
    end

    it "falls back to the newest terminal preview when none are active" do
      job = Factories.job(user: user, repository: repo)
      older = PreviewEnvironment.create!(
        job: job,
        state: "stopped",
        port: 20_100,
        internal_host: "127.0.0.1",
        workspace_path: "/tmp/preview-stopped",
        created_at: 10.minutes.ago
      )
      newer = PreviewEnvironment.create!(
        job: job,
        state: "failed",
        port: 20_101,
        internal_host: "127.0.0.1",
        workspace_path: "/tmp/preview-failed",
        error_message: "boot failed",
        created_at: 5.minutes.ago
      )

      expect(payload_for(job)[:preview]).to include(
        id: newer.id,
        state: "failed"
      )
      expect(payload_for(job)[:preview]).not_to include(id: older.id)
    end
  end
end
