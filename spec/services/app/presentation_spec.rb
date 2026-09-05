require "rails_helper"

RSpec.describe App::Presentation do
  describe ".pending_action_label and .pending_action_detail" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
    let(:job) { Factories.job_record(user: user, repository: repository) }

    it "labels and details a reconcile_job_state repair action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "reconcile_job_state",
        reason: "Job is stuck ready with a merged PR.",
        payload: { "job_id" => job.id, "mode" => "mark_implemented_from_ready_pr" }
      )

      expect(described_class.pending_action_label(action)).to eq("Reconcile state for JOB-#{job.id} (mark_implemented_from_ready_pr)")
      expect(described_class.pending_action_detail(action)).to eq("Mode: mark_implemented_from_ready_pr")
    end

    it "labels and details a force_state_transition repair action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "force_state_transition",
        reason: "Deploy hung the workflow in running.",
        payload: { "job_id" => job.id, "event" => "force_fail" }
      )

      expect(described_class.pending_action_label(action)).to eq("Force force_fail on JOB-#{job.id}")
      expect(described_class.pending_action_detail(action)).to eq("Event: force_fail")
    end

    it "labels and details a cancel_stale_work repair action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "cancel_stale_work",
        reason: "Zombie run after a deploy.",
        payload: { "job_id" => job.id, "workflow_ids" => [ 7 ], "run_ids" => [ 11, 12 ] }
      )

      expect(described_class.pending_action_label(action)).to eq("Cancel stale work for JOB-#{job.id}")
      expect(described_class.pending_action_detail(action)).to eq("Workflows: 7\nRuns: 11, 12")
    end

    it "labels and details a reenqueue_work repair action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "reenqueue_work",
        reason: "Queued run was never picked up.",
        payload: { "job_id" => job.id, "run_id" => 42 }
      )

      expect(described_class.pending_action_label(action)).to eq("Re-enqueue work for JOB-#{job.id}")
      expect(described_class.pending_action_detail(action)).to eq("Run: #42")
    end

    it "labels and details a rerun_ci_repair repair action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "rerun_ci_repair",
        reason: "First repair attempt missed the real failure.",
        payload: { "job_id" => job.id, "instructions" => "Focus on the flaky spec." }
      )

      expect(described_class.pending_action_label(action)).to eq("Re-run CI repair for JOB-#{job.id}")
      expect(described_class.pending_action_detail(action)).to eq("Focus on the flaky spec.")
    end

    it "labels and details a mark_ci_repair_noop repair action instead of leaving the card blank" do
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "failed")
      action = chat_session.pending_actions.create!(
        action: "mark_ci_repair_noop",
        reason: "Repair made no branch progress.",
        payload: { "job_id" => job.id, "workflow_id" => workflow.id }
      )

      expect(described_class.pending_action_label(action)).to eq("Mark CI repair as no-op for JOB-#{job.id}")
      expect(described_class.pending_action_detail(action)).to eq("Workflow: ##{workflow.id}")
    end

    it "labels and details a repair_provider_circuit_evidence action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "repair_provider_circuit_evidence",
        reason: "Evidence was misclassified as a rate limit.",
        payload: { "evidence_type" => "ProviderCircuitEvent", "evidence_id" => 99, "repair_status" => "resolved" }
      )

      expect(described_class.pending_action_label(action)).to eq("Repair ProviderCircuitEvent evidence #99")
      expect(described_class.pending_action_detail(action)).to eq("Repair status: resolved")
    end

    it "labels and details a clear_provider_circuit action instead of leaving the card blank" do
      target_user = Factories.user
      action = chat_session.pending_actions.create!(
        action: "clear_provider_circuit",
        reason: "Provider outage is confirmed resolved.",
        payload: { "provider" => "claude", "user_id" => target_user.id, "positive_evidence" => "manual test run succeeded" }
      )

      expect(described_class.pending_action_label(action)).to eq("Clear claude circuit for user ##{target_user.id}")
      expect(described_class.pending_action_detail(action)).to eq("Mode: clear")
    end

    it "labels a wake_provider_admission action instead of leaving the card blank" do
      action = chat_session.pending_actions.create!(
        action: "wake_provider_admission",
        reason: "Admission queue looks stuck.",
        payload: { "provider" => "claude" }
      )

      expect(described_class.pending_action_label(action)).to eq("Wake claude admission")
    end
  end

  describe ".agent_provider_label" do
    it "uses display_name from the registered plugin for known providers" do
      expect(described_class.agent_provider_label("claude")).to eq("Claude Code")
      expect(described_class.agent_provider_label("codex")).to eq("Codex")
    end

    it "titleizes the key as a fallback for unregistered providers" do
      expect(described_class.agent_provider_label("custom_provider")).to eq("Custom Provider")
    end
  end

  describe ".job_slug" do
    it "formats Syrus Job ids distinctly from GitHub issue numbers" do
      job = Factories.job_record(id: 771)

      expect(described_class.job_slug(job)).to eq("JOB-771")
      expect(described_class.job_slug(772)).to eq("JOB-772")
    end

    it "ignores the persisted descriptive slug column and always returns the JOB-<id> form" do
      job = Factories.job_record(id: 772, issue_title: "Extend visual_review when_files_changed to cover plugin frontend UI")
      expect(job[:slug]).to eq("extend-visual_review-when_files_changed-to-cover-p")

      expect(described_class.job_slug(job)).to eq("JOB-772")
    end
  end

  describe ".chat_slug" do
    it "formats a chat's canonical identifier from a record or a bare id" do
      chat = ChatSession.create!(user: Factories.user)

      expect(described_class.chat_slug(chat)).to eq("CHAT-#{chat.id}")
      expect(described_class.chat_slug(chat.id)).to eq("CHAT-#{chat.id}")
      expect(described_class.chat_slug(42)).to eq("CHAT-42")
    end
  end

  describe ".github_app_install_url_for" do
    it "builds a GitHub App install URL for repositories under one owner" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
      repository = Factories.repository(github_owner_id: 987, github_repository_id: 654)

      expect(described_class.github_app_install_url_for(repository)).to eq(
        "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=987&repository_ids[]=654"
      )
    end

    it "returns nil when the GitHub App is not registered" do
      repository = Factories.repository(github_owner_id: 987, github_repository_id: 654)

      expect(described_class.github_app_install_url_for(repository)).to be_nil
    end
  end

  describe ".github_app_generic_install_url" do
    it "builds a repo-agnostic install URL when the App is registered" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")

      expect(described_class.github_app_generic_install_url).to eq(
        "https://github.com/apps/operator-syrus/installations/new"
      )
    end

    it "returns nil when the App is not registered" do
      expect(described_class.github_app_generic_install_url).to be_nil
    end
  end

  describe ".job_summary_state" do
    it "keeps external takeover closures in the preempted bucket" do
      job = Factories.job_record(state: "closed", closure_reason: "external_pr_merged")

      expect(described_class.job_summary_state(job)).to eq("preempted")
    end

    it "returns the job state otherwise" do
      job = Factories.job_record(state: "implemented")

      expect(described_class.job_summary_state(job)).to eq("implemented")
    end
  end

  describe ".workflow_dashboard_state" do
    it "labels cancelled auto-merge workflows as postponed" do
      expect(described_class.workflow_dashboard_state("cancelled", "auto_merge")).to eq("postponed")
    end

    it "leaves ordinary workflow states unchanged" do
      expect(described_class.workflow_dashboard_state("cancelled", "initial")).to eq("cancelled")
      expect(described_class.workflow_dashboard_state("running", "auto_merge")).to eq("running")
    end
  end

  describe ".current_step_caption" do
    it "returns nil without a running workflow" do
      job = Factories.job_record

      expect(described_class.current_step_caption(job)).to be_nil
    end

    it "describes the running workflow step" do
      job = Factories.job_record
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")
      attach_active_work_unit!(job, workflow)

      expect(described_class.current_step_caption(job)).to eq("currently: Implement (workflow: initial)")
    end

    it "uses projected Step state when the running Run and Step row drift" do
      job = Factories.job_record
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded")
      Step.create!(workflow: workflow, kind: "summarize", position: 1, state: "queued")
      Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")
      attach_active_work_unit!(job, workflow)

      expect(described_class.current_step_caption(job)).to eq("currently: Implement (workflow: initial)")
    end

    it "ignores unowned running workflow rows" do
      job = Factories.job_record
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")

      expect(described_class.current_step_caption(job)).to be_nil
    end
  end

  describe "job URLs" do
    it "builds GitHub issue and PR URLs from the repository slug" do
      repository = Factories.repository(owner: "acme", name: "widgets")
      job = Factories.job_record(repository: repository, issue_number: 17, pr_number: 4, external_pr_number: 5)

      expect(described_class.job_issue_url(job)).to eq("https://github.com/acme/widgets/issues/17")
      expect(described_class.job_pr_url(job)).to eq("https://github.com/acme/widgets/pull/4")
      expect(described_class.external_pr_url(job)).to eq("https://github.com/acme/widgets/pull/5")
    end
  end

  describe ".pr_external?" do
    it "is false when the Job has its own Syrus-opened PR" do
      job = Factories.job_record(pr_number: 4, external_pr_number: nil)

      expect(described_class.pr_external?(job)).to eq(false)
    end

    it "is true when only an externally authored PR is on record" do
      job = Factories.job_record(pr_number: nil, external_pr_number: 5)

      expect(described_class.pr_external?(job)).to eq(true)
    end

    it "is false when there is no PR at all" do
      job = Factories.job_record(pr_number: nil, external_pr_number: nil)

      expect(described_class.pr_external?(job)).to eq(false)
    end
  end

  describe ".epic_state_transition_options" do
    it "lists operator transitions for ready epics" do
      epic = Factories.epic(state: "ready")

      expect(described_class.epic_state_transition_options(epic)).to include(
        [ "Move to backlog", "backlog" ],
        [ "Start", "in_progress" ],
        [ "Archive", "archived" ]
      )
    end
  end

  def attach_active_work_unit!(job, workflow)
    intent = WorkIntent.create!(
      kind: workflow.trigger_kind,
      state: "requested",
      scope_type: "job",
      scope_id: job.id,
      repository: job.repository,
      requested_at: Time.current
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: workflow.trigger_kind,
      state: "running",
      scope_type: "job",
      scope_id: job.id,
      repository: job.repository,
      workflow: workflow
    )
    WorkUnitMember.create!(work_unit: unit, job: job, role: "primary")
  end
end
