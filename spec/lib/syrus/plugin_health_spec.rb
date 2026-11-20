require "rails_helper"

RSpec.describe Syrus::PluginHealth do
  it "uses one finding format for conformance and runtime failures" do
    conformance = described_class::Finding.conformance(
      plugin: "ruby", family: :ecosystem, provider: "Ruby::Ecosystem",
      code: :missing_capability, message: "missing detect_prepare"
    )
    error = RuntimeError.new("detector failed")
    error.set_backtrace([ "plugin.rb:1" ])
    runtime = described_class::Finding.runtime(
      plugin: "ruby", family: :ecosystem, provider: "Ruby::Ecosystem",
      operation: :detect_prepare, exception: error
    )

    expect(conformance).to have_attributes(
      source: :conformance, code: :missing_capability, operation: nil, count: 1
    )
    expect(runtime).to have_attributes(
      source: :runtime, code: :runtime_failure, operation: :detect_prepare,
      exception_class: "RuntimeError", message: "detector failed", backtrace: [ "plugin.rb:1" ], count: 1
    )
  end

  def manifest(name, depends_on: [], conflicts_with: [], optionally_depends_on: [])
    Syrus::Plugin::Manifest.new(
      name: name, version: "1.0.0", provides: {}, metadata: {},
      depends_on: depends_on, conflicts_with: conflicts_with,
      optionally_depends_on: optionally_depends_on
    )
  end

  def external_manifest(scan:, requires_syrus: nil)
    Syrus::Plugin::Manifest.new(name: "external", version: "1.0.0", provides: {}, external: true,
      requires_syrus:, metadata: { plugin_host_surface_scan: scan })
  end

  def scan(legacy: [], unlisted: [], dynamic: [], minimum: nil, error: nil)
    Syrus::PluginHostSurface::Scanner::Result.new(public: [], legacy:, unlisted:, dynamic:,
      minimum_syrus_version: minimum, content_hash: "digest", error:)
  end

  def health(manifests, enabled: nil)
    described_class.new(manifests, enabled_names: enabled || manifests.map(&:name))
  end

  it "reports ok when every hard dependency is installed and enabled" do
    subject = health([ manifest("ruby"), manifest("rails", depends_on: [ "ruby" ]) ])

    expect(subject.status("rails").state).to eq(:ok)
    expect(subject.unhealthy).to eq([])
  end

  it "degrades a plugin whose hard dependency is not installed" do
    subject = health([ manifest("rails", depends_on: [ "ruby" ]) ])

    status = subject.status("rails")
    expect(status.state).to eq(:degraded)
    expect(status.reasons).to include("requires ruby, which is not installed")
    expect(subject.healthy?("rails")).to be(false)
  end

  it "degrades a plugin whose hard dependency is installed but disabled" do
    manifests = [ manifest("ruby"), manifest("rails", depends_on: [ "ruby" ]) ]
    subject = health(manifests, enabled: [ "rails" ])

    expect(subject.status("rails").reasons).to include("requires ruby, which is disabled")
  end

  it "leaves a disabled plugin ok when its own dependency is disabled too" do
    manifests = [ manifest("plugin_runtime"), manifest("git_mirror", depends_on: [ "plugin_runtime" ]) ]
    subject = health(manifests, enabled: [])

    expect(subject.status("git_mirror").state).to eq(:ok)
    expect(subject.unhealthy).to eq([])
  end

  it "leaves a disabled plugin ok when it conflicts with an enabled one" do
    subject = health([ manifest("a", conflicts_with: [ "b" ]), manifest("b") ], enabled: [ "b" ])

    expect(subject.status("a").state).to eq(:ok)
  end

  it "still reports a cycle among disabled plugins" do
    manifests = [ manifest("a", depends_on: [ "b" ]), manifest("b", depends_on: [ "a" ]) ]

    expect(health(manifests, enabled: []).status("a").state).to eq(:cycle)
  end

  it "leaves a plugin ok when only an optional dependency is missing" do
    subject = health([ manifest("chat", optionally_depends_on: [ "design_docs" ]) ])

    expect(subject.status("chat").state).to eq(:ok)
  end

  it "degrades both sides of an enabled conflict" do
    manifests = [ manifest("memory_a", conflicts_with: [ "memory_b" ]),
                  manifest("memory_b", conflicts_with: [ "memory_a" ]) ]
    subject = health(manifests)

    expect(subject.status("memory_a").state).to eq(:degraded)
    expect(subject.status("memory_a").reasons).to include("conflicts with memory_b, which is enabled")
  end

  it "ignores a conflict with a plugin that is disabled" do
    manifests = [ manifest("memory_a", conflicts_with: [ "memory_b" ]), manifest("memory_b") ]
    subject = health(manifests, enabled: [ "memory_a" ])

    expect(subject.status("memory_a").state).to eq(:ok)
  end

  it "marks every member of a dependency cycle" do
    manifests = [ manifest("a", depends_on: [ "b" ]), manifest("b", depends_on: [ "a" ]) ]
    subject = health(manifests)

    expect(subject.status("a").state).to eq(:cycle)
    expect(subject.status("b").state).to eq(:cycle)
    expect(subject.cycles.size).to eq(1)
  end

  it "reports a cycle once regardless of which member it is discovered from" do
    manifests = [ manifest("a", depends_on: [ "b" ]),
                  manifest("b", depends_on: [ "c" ]),
                  manifest("c", depends_on: [ "a" ]) ]

    expect(health(manifests).cycles.size).to eq(1)
  end

  it "does not loop forever on a self-dependency" do
    expect { health([ manifest("a", depends_on: [ "a" ]) ]).statuses }.not_to raise_error
  end

  it "treats an unknown plugin name as healthy" do
    expect(health([ manifest("ruby") ]).healthy?("nonexistent")).to be(true)
  end

  it "warns without disabling an external plugin that uses unsupported APIs" do
    subject = health([ external_manifest(scan: scan(unlisted: [ double ])) ])
    expect(subject.status("external")).to have_attributes(state: :warning)
    expect(subject.healthy?("external")).to be(true)
  end

  it "does not warn for a clean external plugin" do
    expect(health([ external_manifest(scan: scan) ]).status("external").state).to eq(:ok)
  end

  it "records a non-fatal scan error" do
    subject = health([ external_manifest(scan: scan(error: "Prism failed")) ])
    expect(subject.status("external").reasons.join).to include("Prism failed")
    expect(subject.healthy?("external")).to be(true)
  end

  it "warns without disabling for a literal dynamic core reference" do
    subject = health([ external_manifest(scan: scan(dynamic: [ double ])) ])

    expect(subject.status("external")).to have_attributes(state: :warning)
    expect(subject.status("external").reasons.join).to include("dynamic")
  end

  it "warns when requires_syrus is below the derived minimum" do
    requirement = Gem::Requirement.new(">= 0.1.0")
    subject = health([ external_manifest(scan: scan(minimum: "0.2.0"), requires_syrus: requirement) ])
    expect(subject.status("external").reasons.join).to include("0.2.0")
  end
end
