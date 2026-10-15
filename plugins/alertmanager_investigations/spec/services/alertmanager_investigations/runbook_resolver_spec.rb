require "rails_helper"

RSpec.describe AlertmanagerInvestigations::RunbookResolver do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "infra", default_branch: "main") }
  let(:configuration) { instance_double(AlertmanagerInvestigations::Configuration, runbook_allowed?: true) }
  let(:runbook) { "---\nautonomous-investigation: true\n---\nmain runbook" }

  it "resolves an explicitly allowed and opted-in runbook on the default branch" do
    stub_repository_content(repository, files: { "runbooks/disk.md" => runbook })

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/disk.md",
      configuration: configuration
    )

    expect(result).to have_attributes(
      repository: repository,
      ref: "main",
      path: "runbooks/disk.md",
      content: runbook
    )
  end

  it "strips query strings and fragments from pasted GitHub runbook URLs" do
    stub_repository_content(repository, files: {
      "runbooks/disk.md" => runbook
    })

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/disk.md?plain=1#disk-full",
      configuration: configuration
    )

    expect(result).to have_attributes(
      repository: repository,
      ref: "main",
      path: "runbooks/disk.md",
      content: runbook
    )
  end

  it "rejects repositories or paths outside the configured allowlist" do
    stub_repository_content(repository, files: { "runbooks/disk.md" => runbook })
    configuration = instance_double(AlertmanagerInvestigations::Configuration, runbook_allowed?: false)

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/disk.md",
      configuration: configuration
    )

    expect(result).to be_nil
  end

  it "rejects non-default refs" do
    stub_repository_content(repository, ref: "release", files: { "runbooks/disk.md" => runbook })

    result = described_class.call(
      "https://github.com/acme/infra/blob/release/runbooks/disk.md",
      configuration: configuration
    )

    expect(result).to be_nil
  end

  it "rejects files without the explicit front-matter opt-in" do
    stub_repository_content(repository, files: { "runbooks/disk.md" => "# Ordinary documentation" })

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/disk.md",
      configuration: configuration
    )

    expect(result).to be_nil
  end

  it "rejects paths containing traversal segments before reading repository content" do
    expect(RepositoryContent).not_to receive(:for)

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/../README.md",
      configuration: configuration
    )

    expect(result).to be_nil
  end

  it "rejects runbooks larger than the bounded repository read" do
    oversized = "---\nautonomous-investigation: true\n---\n#{"x" * described_class::MAX_RUNBOOK_BYTES}"
    stub_repository_content(repository, files: { "runbooks/disk.md" => oversized })

    result = described_class.call(
      "https://github.com/acme/infra/blob/main/runbooks/disk.md",
      configuration: configuration
    )

    expect(result).to be_nil
  end
end
