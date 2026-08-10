require "rails_helper"

RSpec.describe ProviderCircuitClearance do
  let!(:admin) { Factories.user(admin: true) }
  let(:target_user) { Factories.user }

  def clearance(**overrides)
    described_class.call(**{
      provider: "claude",
      target_user: target_user,
      mode: "clear",
      reason: "provider recovered",
      user: admin,
      positive_evidence: "Ran a successful job manually"
    }.merge(overrides))
  end

  describe ".call" do
    context "validation" do
      it "raises when called by a non-admin user" do
        non_admin = Factories.user

        expect { clearance(user: non_admin) }
          .to raise_error(ArgumentError, /Admin access required/)
      end

      it "raises when provider is blank" do
        expect { clearance(provider: "") }
          .to raise_error(ArgumentError, /provider is required/)
      end

      it "raises when target_user is nil" do
        expect { clearance(target_user: nil) }
          .to raise_error(ArgumentError, /user is required/)
      end

      it "raises for an invalid mode" do
        expect { clearance(mode: "blast_it") }
          .to raise_error(ArgumentError, /mode is invalid/)
      end

      it "raises when reason is blank" do
        expect { clearance(reason: "") }
          .to raise_error(ArgumentError, /reason is required/)
      end

      it "raises when positive_evidence is blank" do
        expect { clearance(positive_evidence: "   ") }
          .to raise_error(ArgumentError, /positive_evidence is required/)
      end

      it "raises when unrepaired structured quota evidence exists for the provider" do
        ProviderAvailabilityEvidence.create!(
          user: target_user,
          provider: "claude",
          status: "exhausted",
          source: "usage_probe",
          observed_at: 5.minutes.ago,
          details: { "snapshot" => { "limit" => 100, "used" => 100 } }
        )

        expect { clearance }
          .to raise_error(ArgumentError, /structured quota evidence is still open/)
      end
    end

    context "successful clearance" do
      it "creates a positive availability evidence record" do
        expect { clearance }
          .to change(ProviderAvailabilityEvidence, :count).by(1)

        evidence = ProviderAvailabilityEvidence.last
        expect(evidence.provider).to eq("claude")
        expect(evidence.user).to eq(target_user)
        expect(evidence.status).to eq("available")
        expect(evidence.source).to eq("operator_circuit_repair")
      end

      it "accepts the shorten mode" do
        expect { clearance(mode: "shorten") }
          .to change(ProviderAvailabilityEvidence, :count).by(1)
      end

      it "records the repaired_by_user_id in the evidence details" do
        clearance

        evidence = ProviderAvailabilityEvidence.last
        expect(evidence.details["repaired_by_user_id"]).to eq(admin.id)
      end

      it "records the retry_after timestamp when provided" do
        future_time = 2.hours.from_now.iso8601

        clearance(retry_after: future_time)

        evidence = ProviderAvailabilityEvidence.last
        expect(evidence.details["retry_after"]).to be_present
      end

      it "raises when retry_after is an out-of-range date" do
        expect { clearance(retry_after: "2026-99-99") }
          .to raise_error(ArgumentError, /retry_after is invalid/)
      end

      it "creates codex success evidence for codex provider" do
        expect { clearance(provider: "codex") }
          .to change(ProviderAvailabilityEvidence, :count).by(1)

        evidence = ProviderAvailabilityEvidence.last
        expect(evidence.provider).to eq("codex")
        expect(evidence.source).to eq("operator_circuit_repair")
      end

      it "proceeds when unrepaired structured quota evidence exists for a different provider" do
        ProviderAvailabilityEvidence.create!(
          user: target_user,
          provider: "codex",
          status: "exhausted",
          source: "usage_probe",
          observed_at: 5.minutes.ago,
          details: { "snapshot" => { "limit" => 100, "used" => 100 } }
        )

        expect { clearance(provider: "claude") }
          .to change(ProviderAvailabilityEvidence, :count).by(1)
      end
    end
  end
end
