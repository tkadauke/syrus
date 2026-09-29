require "rails_helper"

RSpec.describe PlannedExecutionRequestAnalyzer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def job(title:, body: "")
    user.jobs.new(repository: repository, issue_title: title, issue_body: body)
  end

  def loaded_config(yaml)
    RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new(yaml).parse,
      source: ".syrus.yml",
      note: nil,
      outcome: :loaded
    )
  end

  it "keeps backend-only work on default Linux compute" do
    result = described_class.call(job: job(title: "Add Rails API endpoint", body: "Create a migration and controller."))

    expect(result).not_to be_ambiguous
    expect(result.requirement.to_h).to include(
      "capabilities" => { "os" => [ "linux" ] },
      "source" => "prompt"
    )
  end

  it "places iOS and Xcode work on macOS with Xcode" do
    result = described_class.call(job: job(title: "Fix iOS checkout screen", body: "Update the SwiftUI view and Xcode project."))

    expect(result.requirement.to_h).to include(
      "project_label" => "macOS implementation",
      "capabilities" => { "os" => [ "macos" ], "toolchains" => [ "xcode" ] }
    )
  end

  it "uses macOS as primary placement for mixed iOS and backend work" do
    result = described_class.call(job: job(title: "Add iOS push settings and backend API", body: "Update SwiftUI plus the Rails endpoint."))

    expect(result.requirement.capabilities).to eq("os" => [ "macos" ], "toolchains" => [ "xcode" ])
  end

  it "places Windows work on Windows and preserves an explicit architecture" do
    result = described_class.call(job: job(title: "Fix Windows x64 packaging", body: "Update the PowerShell installer."))

    expect(result.requirement.capabilities).to eq("os" => [ "windows" ], "arch" => [ "x64" ])
  end

  it "uses matching repository target graph capability facts when prompt names the target" do
    config = loaded_config(<<~YAML)
      targets:
        - name: desktop-package
          kind: builder
          command: npm run package
          capabilities:
            os: windows
            arch: arm64
    YAML

    result = described_class.call(
      job: job(title: "Repair desktop-package target", body: "The package builder fails."),
      loaded_config: config
    )

    expect(result.requirement.to_h).to include(
      "project_label" => "desktop-package",
      "target_label" => "//:desktop-package",
      "capabilities" => { "os" => [ "windows" ], "arch" => [ "arm64" ] }
    )
  end

  it "surfaces mutually incompatible primary hosts as ambiguous" do
    result = described_class.call(job: job(title: "Build the iOS app and Windows installer", body: "Update Xcode and MSBuild packaging."))

    expect(result).to be_ambiguous
    expect(result.ambiguous_reason).to include("mutually incompatible")
    expect(result.requirement).to be_nil
  end
end
