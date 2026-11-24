require "rails_helper"

# With the plugin off, Syrus runs without main-branch gating: no work gate, no
# landing pause, no health UI, no workflow kinds, and nothing in core raises.
RSpec.describe "main_branch_health plugin disabled" do
  let(:user) { Factories.user }
  let(:repository) do
    Factories.repository(user: user).tap do |repo|
      repo.update!(
        risk_profile: "production",
        main_branch_health_enabled: true,
        main_branch_repair_blocks_work: true,
        landing_paused: true,
        ci_health: "broken"
      )
    end
  end
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { WorkUnits::Launcher.instantiate(kind: "initial", job: job) }

  def set_plugin_enabled!(enabled)
    PluginRecord.find_or_create_by!(name: "main_branch_health").update!(enabled: enabled)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "vetoes workflow starts and landing while enabled" do
    expect(WorkGates.evaluate(workflow: workflow).vetoes).not_to be_empty
    expect(StepDispatcher.main_health_blocking?(workflow)).to be(true)
    expect(WorkGates.evaluate(job: job, landing: true).vetoes.any?(&:landing?)).to be(true)
  end

  context "when disabled" do
    before do
      repository
      set_plugin_enabled!(false)
    end

    after { set_plugin_enabled!(true) }

    it "starts workflows with no gate and does not pause landing" do
      expect(WorkGates.evaluate(workflow: workflow).vetoes).to be_empty
      expect(StepDispatcher.main_health_blocking?(workflow)).to be(false)
      expect(WorkGates.evaluate(job: job, landing: true).vetoes).to be_empty
      expect(WorkUnits::StartBlock.explain(workflow)).not_to include(reason: "main_branch_health") if WorkUnits::StartBlock.respond_to?(:explain)
    end

    it "contributes no repair classifications, alerts, UI or workflow kinds" do
      expect(Syrus::PluginRegistry.providers_for(:work_gate)).not_to include(MainBranchHealthProvider)
      expect(Syrus::PluginRegistry.providers_for(:repair_classifier)).not_to include(MainBranchHealthProvider)
      expect(Syrus::PluginRegistry.providers_for(:system_alert_provider)).not_to include(MainBranchHealthProvider)
      expect(Workflow::TriggerKind.values).not_to include("main_grader", "main_branch_repair")
      expect(Job::Kind.values).not_to include("main_grader")
      expect(WorkDefinitions.registry.keys).not_to include("main_grader", "main_branch_repair")

      expect(App::UiSlotsPayload.panels_for(slot: "dashboard.banner", context: { user: user })).to eq([])
      expect(Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: user).map { |tab| tab[:id] }).not_to include("health")
      expect(SystemAlerts.collect).to be_an(Array) if SystemAlerts.respond_to?(:collect)
    end
  end

  it "is disableable and refuses to disable with a main-branch workflow in flight" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "main_branch_health" }
    expect(manifest).to be_disableable
    expect(Admin::PluginDisableGuard.blockers_for(manifest)).to eq([])

    main_job = Factories.job_record(user: user, repository: repository)
    Workflow.create!(job: main_job, trigger_kind: "main_grader", state: "running")

    blockers = Admin::PluginDisableGuard.blockers_for(manifest)
    expect(blockers.map(&:kind)).to include("active_workflows")
    expect { Admin::PluginDisableGuard.ensure_disableable!(manifest) }.to raise_error(Admin::PluginDisableGuard::Blocked)
  end
end
