require "rails_helper"

RSpec.describe SmartFolder do
  it "creates the built-in folders as system-owned rows" do
    expect { described_class.ensure_builtins! }.to change(described_class, :count).by(11)

    expect(described_class.builtins.pluck(:name)).to eq([
      "Pinned",
      "In progress",
      "Inbox",
      "Awaiting Epic",
      "Needs review",
      "Awaiting your move",
      "Just failed",
      "In review",
      "Stale",
      "Blocked",
      "Merged this week"
    ])
    expect(described_class.builtins.pluck(:user_id).uniq).to eq([ nil ])
  end

  it "requires user-defined folders to belong to a user" do
    folder = described_class.new(name: "Mine", kind: "user_defined", filter: { "state" => "open" })

    expect(folder).not_to be_valid
    expect(folder.errors[:user]).to include("must be present for user-defined smart folders")
  end
end
