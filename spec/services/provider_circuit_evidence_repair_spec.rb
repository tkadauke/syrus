require "rails_helper"

RSpec.describe ProviderCircuitEvidenceRepair do
  let!(:admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }

  def failed_run(user: owner)
    job = Factories.job(repository: Factories.repository(user: user))
    Run.create!(
      job: job,
      user: user,
      step: job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: "claude",
      finished_at: 5.minutes.ago
    )
  end

  def negative_evidence(user: owner)
    ProviderAvailabilityEvidence.create!(
      user: user,
      provider: "claude",
      status: "exhausted",
      source: "chat_turn_failure",
      observed_at: 5.minutes.ago
    )
  end

  def failed_classification(run: nil)
    r = run || failed_run
    r.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.9,
      retryable: false,
      reason: "usage exhausted",
      classified_at: Time.current
    )
  end

  describe ".call" do
    context "validation" do
      it "raises when called by a non-admin user" do
        non_admin = Factories.user
        evidence = negative_evidence

        expect do
          described_class.call(
            evidence_type: "provider_availability_evidence",
            evidence_id: evidence.id,
            repair_status: "false_positive",
            reason: "misclassified",
            user: non_admin
          )
        end.to raise_error(ArgumentError, /Admin access required/)
      end

      it "raises for an unknown evidence_type" do
        evidence = negative_evidence

        expect do
          described_class.call(
            evidence_type: "something_else",
            evidence_id: evidence.id,
            repair_status: "false_positive",
            reason: "misclassified",
            user: admin
          )
        end.to raise_error(ArgumentError, /evidence_type is invalid/)
      end

      it "raises for an invalid repair_status" do
        evidence = negative_evidence

        expect do
          described_class.call(
            evidence_type: "provider_availability_evidence",
            evidence_id: evidence.id,
            repair_status: "nah_ignore_it",
            reason: "misclassified",
            user: admin
          )
        end.to raise_error(ArgumentError, /repair_status is invalid/)
      end

      it "raises when reason is blank" do
        evidence = negative_evidence

        expect do
          described_class.call(
            evidence_type: "provider_availability_evidence",
            evidence_id: evidence.id,
            repair_status: "false_positive",
            reason: "",
            user: admin
          )
        end.to raise_error(ArgumentError, /reason is required/)
      end

      it "raises for structured quota evidence on provider_availability_evidence" do
        run = failed_run
        structured_evidence = ProviderAvailabilityEvidence.create!(
          user: owner,
          run: run,
          provider: "codex",
          status: "exhausted",
          source: "usage_probe",
          observed_at: 5.minutes.ago,
          details: { "snapshot" => { "limit" => 100, "used" => 100 } }
        )

        expect do
          described_class.call(
            evidence_type: "provider_availability_evidence",
            evidence_id: structured_evidence.id,
            repair_status: "false_positive",
            reason: "should use clearance instead",
            user: admin
          )
        end.to raise_error(ArgumentError, /structured quota evidence/)
      end
    end

    context "repairing provider_availability_evidence" do
      it "marks the evidence as repaired with the given status and reason" do
        evidence = negative_evidence

        result = described_class.call(
          evidence_type: "provider_availability_evidence",
          evidence_id: evidence.id,
          repair_status: "false_positive",
          reason: "transient provider glitch, not a real quota issue",
          user: admin
        )

        expect(result).to eq(evidence.reload)
        expect(result.repair_status).to eq("false_positive")
        expect(result.repair_reason).to eq("transient provider glitch, not a real quota issue")
        expect(result.repaired_by_user).to eq(admin)
        expect(result.repaired_at).not_to be_nil
      end

      it "accepts all valid repair statuses" do
        %w[false_positive inconclusive transient].each do |status|
          evidence = negative_evidence

          result = described_class.call(
            evidence_type: "provider_availability_evidence",
            evidence_id: evidence.id,
            repair_status: status,
            reason: "testing status #{status}",
            user: admin
          )

          expect(result.repair_status).to eq(status)
        end
      end
    end

    context "repairing run_failure_classification" do
      it "marks the classification as repaired" do
        classification = failed_classification

        result = described_class.call(
          evidence_type: "run_failure_classification",
          evidence_id: classification.id,
          repair_status: "inconclusive",
          reason: "codex model-decode failure mis-tagged as usage limit",
          user: admin
        )

        expect(result).to eq(classification.reload)
        expect(result.repair_status).to eq("inconclusive")
        expect(result.repair_reason).to eq("codex model-decode failure mis-tagged as usage limit")
        expect(result.repaired_by_user).to eq(admin)
      end

      it "sets repaired_for_circuit? to true after repair" do
        classification = failed_classification
        expect { described_class.call(
          evidence_type: "run_failure_classification",
          evidence_id: classification.id,
          repair_status: "false_positive",
          reason: "misclassified",
          user: admin
        ) }.to change { classification.reload.repaired_for_circuit? }.from(false).to(true)
      end
    end
  end
end
