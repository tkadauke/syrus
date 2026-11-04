require "rails_helper"

RSpec.describe Coworkers::ClaimedWorkspacePaths do
  it "extracts explicit memory and identity-file claims without treating prose as paths" do
    summary = <<~TEXT
      Updated `memory/daily/2026-11-04.md`, memory/repos/acme__app.md, and `SOUL.md`.
      I also reviewed the repository and https://example.com/report.md.
    TEXT

    expect(described_class.from(summary)).to eq(
      [ "memory/daily/2026-11-04.md", "SOUL.md", "memory/repos/acme__app.md" ]
    )
  end

  it "rejects traversal claims and returns no paths for an ordinary no-change summary" do
    expect(described_class.from("Checked `memory/../SOUL.md`; no changes were needed.")).to be_empty
    expect(described_class.from("Everything is already current.")).to be_empty
  end
end
