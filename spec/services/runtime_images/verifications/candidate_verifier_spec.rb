require "rails_helper"

RSpec.describe RuntimeImages::Verifications::CandidateVerifier do
  it "returns the configured check from the shared suite result" do
    expected = RuntimeImages::Verifications::Result.pass(evidence_references: [ { "kind" => "smoke" } ])
    image = double("image")
    context = { build_request_id: 123 }
    suite = instance_double(RuntimeImages::Verifications::CandidateSuite)
    allow(suite).to receive(:result).with(image, context).and_return("smoke_test" => expected)

    result = described_class.new(suite, "smoke_test").call(image: image, context: context, ignored: true)

    expect(result).to equal(expected)
  end

  it "fails when the suite omits the configured check" do
    suite = instance_double(RuntimeImages::Verifications::CandidateSuite, result: {})
    verifier = described_class.new(suite, "smoke_test")

    expect { verifier.call(image: double("image"), context: {}) }.to raise_error(KeyError)
  end
end
