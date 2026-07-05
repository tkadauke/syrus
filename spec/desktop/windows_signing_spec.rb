# frozen_string_literal: true

require "yaml"
require "spec_helper"

# Azure Artifact Signing wiring (docs/windows-signing.md). The invariant
# that matters: win.azureSignOptions must NEVER land in the committed
# electron-builder.yml, because its mere presence (unlike macOS's
# CSC_LINK) makes electron-builder attempt Azure signing unconditionally —
# that would break every unsigned local/dev Windows cross-build.
RSpec.describe "Windows code signing (Azure Artifact Signing)" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(*segments)
    File.read(File.join(*segments), encoding: "UTF-8")
  end

  let(:builder_config) { read(desktop_root, "electron-builder.yml") }
  # Windows signing lives in the release pipeline's build-windows job. There is
  # no separate signing-test workflow — a dry-run release signs Windows the
  # same way, so the release job IS the harness.
  let(:release_workflow) { read(repo_root, ".github/workflows/release.yml") }

  it "never commits azureSignOptions as static config" do
    expect(builder_config).not_to include("azureSignOptions")
  end

  it "guards on all required Azure config before attempting a build" do
    required = %w[AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_SIGN_ENDPOINT AZURE_SIGN_ACCOUNT_NAME AZURE_SIGN_CERT_PROFILE AZURE_SIGN_PUBLISHER_NAME]
    required.each { |var| expect(release_workflow).to include(var) }
    expect(release_workflow).to match(/Guard: Azure signing configuration present/)
  end

  it "injects azureSignOptions via CLI overrides, not the committed config" do
    expect(release_workflow).to include("-c.win.azureSignOptions.publisherName=")
    expect(release_workflow).to include("-c.win.azureSignOptions.endpoint=")
    expect(release_workflow).to include("-c.win.azureSignOptions.certificateProfileName=")
    expect(release_workflow).to include("-c.win.azureSignOptions.codeSigningAccountName=")
  end

  it "verifies the resulting signature is Valid before staging anything" do
    expect(release_workflow).to include("Get-AuthenticodeSignature")
    expect(release_workflow).to match(/if \(\$sig\.Status -ne "Valid"\)/)
  end

  it "documents the exact secrets in windows-signing.md" do
    doc = read(repo_root, "docs/windows-signing.md")
    %w[AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_SIGN_ENDPOINT AZURE_SIGN_ACCOUNT_NAME AZURE_SIGN_CERT_PROFILE AZURE_SIGN_PUBLISHER_NAME].each do |var|
      expect(doc).to include(var)
    end
    expect(doc).to include("Trusted Signing Certificate Profile Signer")
    plan = read(repo_root, "docs/windows-desktop-plan.md")
    expect(plan).to include("windows-signing.md")
  end
end
