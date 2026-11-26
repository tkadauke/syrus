require "rails_helper"

RSpec.describe RuntimeImageVerificationSweepJob do
  it "uses the current vulnerability database revision for every available image" do
    image = instance_double(RuntimeImage)
    scanner = instance_double(RuntimeImages::Verifications::SupplyChainScanner, current_database_version: "db-2")
    reevaluator = instance_double(RuntimeImages::Verifications::Reevaluator, call: nil)
    allow(RuntimeImages::Verifications::SupplyChainScanner).to receive(:new).and_return(scanner)
    allow(RuntimeImages::Verifications::Reevaluator).to receive(:new).and_return(reevaluator)
    allow(RuntimeImage).to receive_message_chain(:where, :find_each).and_yield(image)

    described_class.perform_now

    expect(reevaluator).to have_received(:call).with(image, database_version: "db-2")
  end
end
