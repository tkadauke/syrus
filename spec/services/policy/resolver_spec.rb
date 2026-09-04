require "rails_helper"

RSpec.describe Policy::Resolver do
  it "takes the first tier that answers and says which one did" do
    result = described_class.call(candidates: [
      [ "Epic#1", -> { nil } ],
      [ "Repository#2", -> { "always" } ],
      [ "User#3", -> { "never" } ]
    ])

    expect(result.value).to eq("always")
    expect(result.source).to eq("Repository#2")
  end

  # Three sibling resolvers currently give three different answers to "what if
  # the repo does not say"; the default is a tier like any other and names
  # itself.
  it "falls through to the declared default" do
    result = described_class.call(candidates: [ [ "Repository#1", -> { nil } ] ], default: "never")

    expect(result.value).to eq("never")
    expect(result.source).to eq("default")
  end

  describe "policy that cannot be read" do
    let(:candidates) do
      [
        [ ".syrus.yml", -> { raise described_class::Unreadable, "GitHub unavailable" } ],
        [ "Repository#1", -> { "relaxed" } ]
      ]
    end

    # A transient GitHub outage silently relaxing a project's risk posture is
    # the defect this exists to prevent.
    it "fails closed rather than falling through to a laxer tier" do
      result = described_class.call(candidates: candidates)

      expect(result).to be_unreadable
      expect(result.value).to be_nil
      expect(result.source).to match(/unreadable: GitHub unavailable/)
    end

    it "can be told to carry on, for a caller that has decided that is safe" do
      result = described_class.call(candidates: candidates, fail_closed: false)

      expect(result).to be_readable
      expect(result.value).to eq("relaxed")
    end
  end

  it "distinguishes a tier that said nothing from one that could not be read" do
    silent = described_class.call(candidates: [ [ "Repository#1", -> { nil } ] ], default: "d")
    unreadable = described_class.call(candidates: [ [ "Repository#1", -> { raise described_class::Unreadable, "x" } ] ])

    expect(silent).to be_readable
    expect(unreadable).to be_unreadable
  end
end
