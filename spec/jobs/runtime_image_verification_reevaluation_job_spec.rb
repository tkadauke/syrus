require "rails_helper"

RSpec.describe RuntimeImageVerificationReevaluationJob do
  it "runs on the cleanup queue" do
    expect(described_class.queue_name).to eq("cleanup")
  end

  it "re-evaluates only due attestations with preloaded build evidence" do
    attestation = instance_double(RuntimeImageVerificationAttestation, runtime_image_id: 7, id: 9)
    relation = instance_double(ActiveRecord::Relation)
    allow(RuntimeImageVerificationAttestation).to receive(:reevaluation_candidates).and_return(relation)
    allow(relation).to receive(:includes).and_return(relation)
    allow(relation).to receive(:order).and_return(relation)
    allow(relation).to receive(:limit).and_return([ attestation ])
    result = instance_double(RuntimeImageBuildResult, runtime_image_id: 7)
    results = instance_double(ActiveRecord::Relation)
    allow(RuntimeImageBuildResult).to receive(:includes).and_return(results)
    allow(results).to receive(:where).and_return(results)
    allow(results).to receive(:index_by).and_return(7 => result)
    reevaluator = instance_double(RuntimeImages::Verifications::Reevaluator, due?: true, call: nil)
    allow(RuntimeImages::Verifications::Reevaluator).to receive(:new).and_return(reevaluator)
    allow(RuntimeImages::Verifications::Policy).to receive(:current).and_return({})

    described_class.perform_now(database_version: "db-2")

    expect(reevaluator).to have_received(:call).with(attestation, policy: {}, now: kind_of(Time), build_result: result)
  end
end
