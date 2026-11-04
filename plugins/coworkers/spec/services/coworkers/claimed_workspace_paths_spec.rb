require "rails_helper"

RSpec.describe Coworkers::ClaimedWorkspacePaths do
  it "extracts explicit memory and identity-file claims without treating prose as paths" do
    summary = <<~TEXT
      Updated `memory/daily/2026-11-04.md`, memory/repos/acme__app.md, and `SOUL.md`.
      I also reviewed the repository and https://example.com/report.md.
    TEXT

    expect(described_class.from(summary)).to eq(
      [ "memory/daily/2026-11-04.md", "memory/repos/acme__app.md", "SOUL.md" ]
    )
  end

  it "rejects traversal claims and returns no paths for an ordinary no-change summary" do
    expect(described_class.from("Checked `memory/../SOUL.md`; no changes were needed.")).to be_empty
    expect(described_class.from("Everything is already current.")).to be_empty
  end

  it "does not treat deleted paths as claims that the files still exist" do
    expect(described_class.from("Deleted `memory/old.md` and removed `SOUL.md`.")).to be_empty
  end

  it "does not treat negative or read-only path mentions as write claims" do
    summary = "I did not update `memory/today.md`. No `memory/tomorrow.md` exists. Read `SOUL.md`; no changes were needed."

    expect(described_class.from(summary)).to be_empty
  end

  it "uses the operation nearest each path when a summary reports deletes and writes" do
    summary = "Deleted `memory/old.md`, then wrote `memory/new.md`."

    expect(described_class.from(summary)).to eq([ "memory/new.md" ])
  end

  it "distinguishes repeated paths mentioned first as read and later as written" do
    summary = "Read `memory/today.md`. Then wrote `memory/today.md`."

    expect(described_class.from(summary)).to eq([ "memory/today.md" ])
  end
end
