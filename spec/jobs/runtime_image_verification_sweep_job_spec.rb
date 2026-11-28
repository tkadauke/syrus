require "rails_helper"

RSpec.describe RuntimeImageVerificationSweepJob do
  it "uses the current vulnerability database revision for every available image" do
    scanner = instance_double(RuntimeImages::Verifications::SupplyChainScanner, current_database_version: "db-2")
    allow(RuntimeImages::Verifications::SupplyChainScanner).to receive(:new).and_return(scanner)
    allow(RuntimeImageVerificationReevaluationJob).to receive(:perform_now)

    described_class.perform_now

    expect(RuntimeImageVerificationReevaluationJob).to have_received(:perform_now).with(database_version: "db-2")
  end
end
