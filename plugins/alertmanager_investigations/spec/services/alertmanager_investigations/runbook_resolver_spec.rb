require "rails_helper"

RSpec.describe AlertmanagerInvestigations::RunbookResolver do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "infra", default_branch: "main") }

  it "resolves a GitHub blob runbook when the ref contains slashes" do
    stub_repository_content(repository, ref: "release/2026-10", files: {
      "runbooks/disk.md" => "release runbook"
    })

    result = described_class.call("https://github.com/acme/infra/blob/release/2026-10/runbooks/disk.md")

    expect(result).to have_attributes(
      repository: repository,
      ref: "release/2026-10",
      path: "runbooks/disk.md",
      content: "release runbook"
    )
  end

  it "strips query strings and fragments from pasted GitHub runbook URLs" do
    stub_repository_content(repository, files: {
      "runbooks/disk.md" => "main runbook"
    })

    result = described_class.call("https://github.com/acme/infra/blob/main/runbooks/disk.md?plain=1#disk-full")

    expect(result).to have_attributes(
      repository: repository,
      ref: "main",
      path: "runbooks/disk.md",
      content: "main runbook"
    )
  end
end
