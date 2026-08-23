require "rails_helper"

RSpec.describe "WorkUnit runtime gates" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { WorkUnits::Launcher.instantiate(kind: "initial", job: job) }
  let(:unit) { workflow.work_unit }

  describe WorkUnits::Gates::MainBranchHealth do
    it "blocks when StepDispatcher main-health policy would block the workflow" do
      allow(StepDispatcher).to receive(:main_health_blocking?).with(workflow).and_return(true)

      result = described_class.call(unit)

      expect(result).to be_blocked
      expect(result.reason).to eq("main_branch_health")
      expect(result.details).to include(
        "repository_id" => repository.id,
        "repository_slug" => repository.slug,
        "main_health_state" => "broken"
      )
    end

    it "passes when main-health policy allows the workflow" do
      allow(StepDispatcher).to receive(:main_health_blocking?).with(workflow).and_return(false)

      expect(described_class.call(unit)).to be_pass
    end
  end

  describe WorkUnits::Gates::ProviderAvailability do
    it "blocks with provider availability details when the provider pause service pauses" do
      retry_at = 15.minutes.from_now
      decision = ProviderAvailabilityPause::Decision.new(
        pause: true,
        reason: "provider_usage_low",
        provider: "codex",
        threshold_percent: 10,
        remaining_percent: 7.5,
        retry_at: retry_at,
        availability: { usage: { status: "warning" }, message: "Codex usage is low" }
      )
      allow(ProviderAvailabilityPause).to receive(:call).with(workflow: workflow).and_return(decision)

      result = described_class.call(unit)

      expect(result).to be_blocked
      expect(result.reason).to eq("provider_availability")
      expect(result.retry_at).to eq(retry_at)
      expect(result.details).to include(
        "provider" => "codex",
        "threshold_percent" => 10,
        "remaining_percent" => 7.5,
        "usage_status" => "warning"
      )
    end

    it "passes when provider availability allows the workflow" do
      decision = ProviderAvailabilityPause::Decision.new(
        pause: false,
        reason: nil,
        provider: "codex",
        threshold_percent: 10,
        remaining_percent: nil,
        retry_at: nil,
        availability: nil
      )
      allow(ProviderAvailabilityPause).to receive(:call).with(workflow: workflow).and_return(decision)

      expect(described_class.call(unit)).to be_pass
    end
  end

  describe WorkUnits::Gates::AdmissionControl do
    it "blocks with admission-control details when workflow admission delays the workflow" do
      retry_at = 10.minutes.from_now
      decision = WorkflowAdmissionBudget::Decision.new(
        action: "delay_until",
        reason: "predicted_budget_pressure_high",
        pressure: { "cpu_pressure" => 120.0 },
        delay_until: retry_at,
        override: nil,
        details: { "decision_basis" => "prediction" }
      )
      allow(WorkflowAdmissionBudget).to receive(:call).with(workflow: workflow).and_return(decision)
      allow(StepDispatcher).to receive(:hard_resource_pause?).with(decision).and_return(false)

      result = described_class.call(unit)

      expect(result).to be_blocked
      expect(result.reason).to eq("admission_control")
      expect(result.retry_at).to eq(retry_at)
      expect(result.details).to include(
        "action" => "delay_until",
        "reason" => "predicted_budget_pressure_high"
      )
    end

    it "maps hard host pressure to resource_safety" do
      decision = WorkflowAdmissionBudget::Decision.new(
        action: "requires_override",
        reason: "worker_memory_exhausted",
        pressure: { "memory_used_percent" => 97.0 },
        delay_until: nil,
        override: nil,
        details: {}
      )
      allow(WorkflowAdmissionBudget).to receive(:call).with(workflow: workflow).and_return(decision)
      allow(StepDispatcher).to receive(:hard_resource_pause?).with(decision).and_return(true)

      result = described_class.call(unit)

      expect(result).to be_blocked
      expect(result.reason).to eq("resource_safety")
    end
  end
end
