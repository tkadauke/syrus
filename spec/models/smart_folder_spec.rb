require "rails_helper"

RSpec.describe SmartFolder do
  it "creates the built-in folders as system-owned rows" do
    expect { described_class.ensure_builtins! }.to change(described_class, :count).by(12)

    expect(described_class::JOB_BUILTINS).to eq(described_class::BUILTIN_DEFINITIONS)
    expect(described_class::EPIC_BUILTINS).to eq([])
    expect(described_class.builtins.pluck(:name)).to eq([
      "Pinned",
      "In progress",
      "Inbox",
      "Awaiting your approval",
      "Landing queue",
      "Just failed",
      "In review",
      "Blocked",
      "Stale",
      "Awaiting Epic",
      "Needs review",
      "Merged this week"
    ])
    expect(described_class.builtins.pluck(:user_id).uniq).to eq([ nil ])
    expect(described_class.builtins.pluck(:subject_type).uniq).to eq([ "job" ])
  end

  it "sweeps retired built-ins on next ensure_builtins!" do
    described_class.create!(name: "Ghost", kind: "builtin", filter: { "attention" => "ghost" }, position: 99)

    expect { described_class.ensure_builtins! }.to change { described_class.exists?(name: "Ghost") }.from(true).to(false)
  end

  it "classifies built-in visibility tiers" do
    described_class.ensure_builtins!
    by_name = described_class.builtins.to_h { |f| [ f.name, f.visibility ] }

    expect(by_name["Inbox"]).to eq(:always)
    expect(by_name["In review"]).to eq(:always)
    expect(by_name["Pinned"]).to eq(:when_present)
    expect(by_name["Stale"]).to eq(:when_present)
    expect(by_name["Merged this week"]).to eq(:on_demand)
    expect(by_name["Needs review"]).to eq(:on_demand)
  end

  it "requires user-defined folders to belong to a user" do
    folder = described_class.new(name: "Mine", kind: "user_defined", filter: { "state" => "open" })

    expect(folder).not_to be_valid
    expect(folder.errors[:user]).to include("must be present for user-defined smart folders")
  end

  it "allows a user to reuse a folder name across subjects" do
    user = Factories.user

    job_folder = described_class.create!(
      user: user,
      name: "In progress",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "open" }
    )
    epic_folder = described_class.create!(
      user: user,
      name: "In progress",
      kind: "user_defined",
      subject_type: "epic",
      filter: { "state" => "open" }
    )

    expect(described_class.for_subject(:job)).to include(job_folder)
    expect(described_class.for_subject(:epic)).to include(epic_folder)
  end

  it "keeps user folder names unique within a subject" do
    user = Factories.user
    described_class.create!(
      user: user,
      name: "Mine",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "open" }
    )

    duplicate = described_class.new(
      user: user,
      name: "Mine",
      kind: "user_defined",
      subject_type: "job",
      filter: { "state" => "closed" }
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to include("has already been taken")
  end
end
