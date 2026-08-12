require "rails_helper"

RSpec.describe AdmissionDiagnostics::Breakdown do
  describe ".for" do
    it "builds a step-profile pressure breakdown from projected pressure vs budget thresholds" do
      result = described_class.for(
        "reason" => "predicted_budget_pressure_high",
        "pressure" => {
          "projected" => { "cpu_pressure" => 132.4, "io_pressure" => 40.0, "memory_used_percent" => 60.0 },
          "host" => { "telemetry_state" => "present" }
        },
        "details" => {}
      )

      expect(result).to include(
        "reason" => "predicted_budget_pressure_high",
        "category" => "step_profile_pressure",
        "telemetry_state" => "present",
        "telemetry_absent" => false
      )
      expect(result["dimensions"]).to contain_exactly(
        { "metric" => "cpu_pressure", "label" => "CPU pressure", "current" => 132.4, "threshold" => WorkflowAdmissionBudget::CPU_BUDGET, "over_threshold" => true },
        { "metric" => "io_pressure", "label" => "IO pressure", "current" => 40.0, "threshold" => WorkflowAdmissionBudget::IO_BUDGET, "over_threshold" => false },
        { "metric" => "memory_used_percent", "label" => "Memory used", "current" => 60.0, "threshold" => WorkflowAdmissionBudget::MEMORY_BUDGET, "over_threshold" => false }
      )
    end

    it "builds a hard host pressure breakdown for the specific tripped metric only" do
      result = described_class.for(
        "reason" => "worker_memory_exhausted",
        "pressure" => {
          "host" => { "max_memory_used_percent" => 97.5, "max_cpu_pressure" => 20.0, "telemetry_state" => "present" }
        },
        "details" => {}
      )

      expect(result["category"]).to eq("hard_host_pressure")
      expect(result["dimensions"]).to eq(
        [ { "metric" => "memory_used_percent", "label" => "Memory used", "current" => 97.5, "threshold" => WorkflowAdmissionBudget::HARD_MEMORY_USED_PERCENT, "over_threshold" => true } ]
      )
    end

    it "builds a soft host pressure breakdown across all ambient metrics" do
      result = described_class.for(
        "reason" => "worker_host_pressure_high",
        "pressure" => {
          "host" => {
            "max_cpu_pressure" => 90.0,
            "max_io_pressure" => 10.0,
            "max_memory_used_percent" => 50.0,
            "max_data_root_used_percent" => 30.0,
            "telemetry_state" => "present"
          }
        },
        "details" => {}
      )

      expect(result["category"]).to eq("soft_host_pressure")
      cpu_dimension = result["dimensions"].find { |dimension| dimension["metric"] == "cpu_pressure" }
      expect(cpu_dimension).to include("current" => 90.0, "threshold" => WorkflowAdmissionBudget::SOFT_HOST_PRESSURE, "over_threshold" => true)
    end

    it "flags telemetry_absent distinctly from a measured reading" do
      result = described_class.for(
        "reason" => "predicted_budget_pressure_high",
        "pressure" => { "projected" => {}, "host" => { "telemetry_state" => "absent" } },
        "details" => {}
      )

      expect(result["telemetry_state"]).to eq("absent")
      expect(result["telemetry_absent"]).to be(true)
    end

    it "flags stale telemetry as absent-equivalent for operator purposes" do
      result = described_class.for(
        "reason" => "predicted_budget_pressure_high",
        "pressure" => { "projected" => {}, "host" => { "telemetry_state" => "stale" } },
        "details" => {}
      )

      expect(result["telemetry_absent"]).to be(true)
    end

    it "falls back to details.telemetry_state when pressure.host is absent" do
      result = described_class.for(
        "reason" => "predicted_budget_pressure_high",
        "pressure" => {},
        "details" => { "telemetry_state" => "absent" }
      )

      expect(result["telemetry_state"]).to eq("absent")
      expect(result["telemetry_absent"]).to be(true)
    end

    it "returns no dimensions when a step-profile reason carries no projected pressure" do
      result = described_class.for("reason" => "repository_concurrency_budget_exhausted", "pressure" => {}, "details" => {})

      expect(result["category"]).to eq("step_profile_pressure")
      expect(result["dimensions"]).to eq([])
    end

    it "categorizes unrecognized reasons as other with no dimensions" do
      result = described_class.for("reason" => "minimum_progress_floor", "pressure" => {}, "details" => {})

      expect(result["category"]).to eq("other")
      expect(result["dimensions"]).to eq([])
    end

    it "handles a blank artifact without raising" do
      result = described_class.for({})

      expect(result["category"]).to eq("other")
      expect(result["dimensions"]).to eq([])
      expect(result["telemetry_absent"]).to be(false)
    end
  end
end
