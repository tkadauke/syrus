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

  describe "machine-appended bug report context" do
    # Built through the formatter itself rather than hand-written, so this
    # cannot drift from what the in-app reporter actually appends. If the
    # section's heading changes, this spec follows it automatically.
    def generated_context(user_agent:)
      formatter = Class.new do
        include BugReports::ContextFormatter
        public :format_context_markdown
      end.new

      formatter.format_context_markdown(
        "url" => "https://example.test/chats/1",
        "user_agent" => user_agent
      )
    end

    # Regression: a User-Agent names the device it came from, so bug reports
    # filed from a phone were read as requiring a macOS worker. Nothing in the
    # fleet advertises those capabilities, so the work blocked on
    # `no_capable_worker` -- which clears only when an operator adds such a
    # worker -- and one stranded Job held its repository's landing slot.
    it "ignores a platform named only by the reporter's User-Agent" do
      body = "The artifact renderer overflows its container." +
             generated_context(user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15")

      result = described_class.call(job: job(title: "Artifact renderer overflow", body: body))

      expect(result).not_to be_ambiguous
      expect(result.requirement&.capabilities.to_h["os"].to_a).not_to include("macos")
    end

    it "still honors a platform the reporter wrote themselves, alongside that context" do
      body = "The Xcode project fails to build." +
             generated_context(user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")

      result = described_class.call(job: job(title: "Fix the build", body: body))

      expect(result.requirement.capabilities).to eq("os" => [ "macos" ], "toolchains" => [ "xcode" ])
    end

    # The divider only delimits the generated section when the heading follows
    # it. A reporter who types one must not have the rest of their report
    # silently dropped.
    it "does not treat a bare divider as the start of generated context" do
      body = "Steps to reproduce:\n\n---\n\nThe Xcode build fails on the second run."

      result = described_class.call(job: job(title: "Build failure", body: body))

      expect(result.requirement.capabilities).to eq("os" => [ "macos" ], "toolchains" => [ "xcode" ])
    end
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

  it "surfaces iOS plus Linux-specific host work as ambiguous" do
    result = described_class.call(job: job(title: "Update Xcode app and Linux service", body: "Repair the iOS project and the systemd unit."))

    expect(result).to be_ambiguous
    expect(result.ambiguous_reason).to include("mutually incompatible")
    expect(result.requirement).to be_nil
  end
end
