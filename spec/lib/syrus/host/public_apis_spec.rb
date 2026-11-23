require "rails_helper"

RSpec.describe Syrus::Host::PublicApis do
  around do |example|
    original_apis = Syrus::Host.apis.dup
    example.run
  ensure
    described_class.install!
    Syrus::Host.apis.replace(original_apis)
  end

  it "rebuilds aliases and contracts without duplicates on every prepare pass" do
    2.times { described_class.install! }

    expect(Syrus::Host.apis.size).to eq(55)
    expect(Syrus::Host.apis.map(&:name).uniq.size).to eq(55)
    expect(Syrus::Host::Record).to equal(ApplicationRecord)
    expect(Syrus::Host::BackgroundJob).to equal(ApplicationJob)
    expect(Syrus::Host::PluginInvocation).to equal(Syrus::PluginInvocation)
    expect(Syrus::Host::BackupArtifactSource).to equal(Syrus::Plugin::BackupArtifactSource)
    expect(Syrus::Host::BackupDestination).to equal(Syrus::Plugin::BackupDestination)
    expect(Syrus::Host::SystemAlertProvider).to equal(Syrus::Plugin::SystemAlertProvider)
    expect(Syrus::Host::ExternalReviewer).to equal(Syrus::Plugin::ExternalReviewer)
    expect(Syrus::Host::ExternalReviewContext).to equal(Syrus::Plugin::ExternalReviewContext)
    expect(Syrus::Host::Toolkit).to equal(Syrus::Plugin::Toolkit)
  end

  it "aliases the ecosystem grader and workspace facades onto their core values" do
    {
      PluginApi: Syrus::PluginApi, GraderStep: SyrusYml::GradeStep, GraderBaseRetry: SyrusYml::BaseRetry,
      GraderResourceRequest: GraderResourceRequest, GraderExecutionCapabilities: TargetGraph::ExecutionCapabilities,
      TestRunResult: JunitXmlParser::ParsedRun, TestCaseResult: JunitXmlParser::ParsedCase,
      CoverageParseResult: CoverageAnalysis::Parsers::Base::ParseResult, WorkflowWorkspace: WorkflowWorkspace,
      GitRunner: GitRunner, CapabilityDescriptor: Permissions::CapabilityDescriptorAdapter
    }.each { |name, core| expect(Syrus::Host.const_get(name)).to equal(core), name.to_s }
  end

  it "exposes the shared grader defaults without the SyrusYml constants" do
    expect(Syrus::Host::GraderDefaults.default_phases).to equal(SyrusYml::DEFAULT_GRADE_PHASES)
    expect(Syrus::Host::GraderDefaults.max_timeout_minutes).to eq(SyrusYml::MAX_GRADE_TIMEOUT_MINUTES)
  end

  it "declares contracts for every promoted ecosystem facade" do
    names = %w[GraderStep GraderBaseRetry GraderDefaults GraderResourceRequest GraderExecutionCapabilities
               TestRunResult TestCaseResult CoverageParseResult WorkflowWorkspace GitRunner CapabilityDescriptor]
    names.each { |name| expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true), name }
    expect(Syrus::Host.apis.find { |api| api.name == "Syrus::Host::McpTools" }.members).to include("run_from_context")
  end

  it "queues chat title generation without exposing the job to plugins" do
    expect {
      Syrus::Host::ChatTitles.enqueue(chat_id: 12, message_id: 34)
    }.to have_enqueued_job(ChatTitleJob).with(12, 34)
  end

  it "reads disk usage without exposing the core service" do
    snapshot = instance_double(DataRootDiskUsage::Snapshot)
    allow(DataRootDiskUsage).to receive(:read).with("/srv/backups").and_return(snapshot)

    expect(Syrus::Host::DiskUsage.read("/srv/backups")).to equal(snapshot)
  end

  it "builds system alerts without exposing the core value class" do
    alert = Syrus::Host::SystemAlert.build(
      id: "plugin:warning", severity: :warn, title: "Warning", message: "Details", action_steps: [ "Inspect it." ]
    )

    expect(alert).to be_a(SystemAlerts::Alert)
    expect(alert.id).to eq("plugin:warning")
  end

  it "requires admin page providers to implement their declared metadata" do
    provider = Class.new { include Syrus::Host::AdminPage }

    expect { provider.admin_pages }.to raise_error(NotImplementedError, /implement \.admin_pages/)
  end

  it "resolves alias targets again instead of retaining an earlier class generation" do
    original = ApplicationRecord
    replacement = Class.new
    Object.send(:remove_const, :ApplicationRecord)
    Object.const_set(:ApplicationRecord, replacement)

    described_class.install!

    expect(Syrus::Host::Record).to equal(replacement)
  ensure
    Object.send(:remove_const, :ApplicationRecord)
    Object.const_set(:ApplicationRecord, original)
  end

  it "does not discard contracts managed by another host API declaration" do
    external = Syrus::Host.api(
      "Syrus::Host::ExternalExample",
      since: "1.2.3",
      summary: "An independently managed contract.",
      members: []
    )

    described_class.install!

    expect(Syrus::Host.apis).to include(external)
  end

  it "keeps each reloadable domain facade in its Zeitwerk-matching file" do
    described_class::DOMAIN_CONTRACTS.each_key do |name|
      path = Rails.root.join("app/models/syrus/host/#{name.to_s.underscore}.rb")

      expect(path).to exist
      expect("Syrus::Host::#{name}".constantize.record_class).to equal(name.to_s.constantize)
    end
  end
end
