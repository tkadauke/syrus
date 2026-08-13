require "rails_helper"

RSpec.describe App::Presentation do
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

      expect(described_class.current_step_caption(job)).to eq("currently: Implement (workflow: initial)")
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
end
