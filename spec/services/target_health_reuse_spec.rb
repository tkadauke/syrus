require "rails_helper"
require "tmpdir"

RSpec.describe TargetHealthReuse do
  let(:repository) { Factories.repository }

  around do |example|
    Dir.mktmpdir("syrus-target-health-reuse") do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  it "reuses target health inside a capability class and rejects records from another class" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/test
    YAML
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return(worker_environment("linux"))
    graph = TargetGraph::Compiler.compile(@dir)
    linux_fingerprints = TargetGraph::Fingerprints.for_target(
      workspace_path: @dir,
      graph: graph,
      label: TargetGraph::Label.parse("//:grade/tests")
    )
    reusable_record = create_record(
      linux_fingerprints,
      metadata: { "target_fingerprint_metadata" => linux_fingerprints.metadata }
    )

    linux_result = described_class.new(repository: repository, graph: graph, workspace_path: @dir)
      .for_target(TargetGraph::Label.parse("//:grade/tests"))
    expect(linux_result).to be_reusable
    expect(linux_result.record).to eq(reusable_record)

    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata).and_return(worker_environment("macos"))
    mac_result = described_class.new(repository: repository, graph: graph, workspace_path: @dir)
      .for_target(TargetGraph::Label.parse("//:grade/tests"))

    expect(mac_result).not_to be_reusable
    expect(mac_result.record).to be_nil
    expect(mac_result.reason).to include("environment/capability mismatch")
    expect(mac_result.reason).to include("cached os=linux")
    expect(mac_result.reason).to include("current os=macos")
  end

  def create_record(fingerprints, metadata:)
    TargetHealthRecord.create!(
      repository: repository,
      target_label: "//:grade/tests",
      project_id: TargetGraph::ROOT_PROJECT_ID,
      commit_sha: "a" * 40,
      input_fingerprint: fingerprints.input_fingerprint,
      command_fingerprint: fingerprints.command_fingerprint,
      environment_fingerprint: fingerprints.environment_fingerprint,
      status: "passed",
      checked_at: Time.current,
      metadata: metadata
    )
  end

  def write(relative_path, contents)
    path = @dir.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(contents)
  end

  def worker_environment(os)
    {
      "capabilities" => { "os" => [ os ], "arch" => [ "arm64" ] },
      "runtime" => { "ruby_platform" => "#{os}-ruby" },
      "tool_versions" => { "ruby" => "ruby 3.4.10" }
    }
  end
end
