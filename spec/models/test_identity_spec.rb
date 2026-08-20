require "rails_helper"

RSpec.describe TestIdentity do
  describe ".ensure_for_cases!" do
    let(:repository) { Factories.repository }
    let(:test_case) do
      TestCase.new(
        repository: repository,
        suite_name: "MySpec",
        name: "does the thing",
        status: "passed"
      )
    end

    it "uses adapter-portable inserts for missing identities" do
      allow(described_class).to receive(:insert_all).and_call_original

      described_class.ensure_for_cases!(repository: repository, cases: [ test_case ])

      expect(described_class).to have_received(:insert_all) do |_rows, **options|
        expect(options).to be_empty
      end
    end
  end
end
