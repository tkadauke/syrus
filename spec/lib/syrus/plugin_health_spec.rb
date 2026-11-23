require "rails_helper"

RSpec.describe Syrus::PluginHealth do
  it "uses one finding record for conformance and runtime failures" do
    conformance = described_class::Finding.conformance(
      plugin: "ruby", family: :ecosystem, provider: "Ruby::Ecosystem",
      code: :missing_capability, message: "missing detect_prepare"
    )
    error = RuntimeError.new("detector failed")
    error.set_backtrace([ "plugin.rb:1" ])
    runtime = described_class::Finding.runtime(
      plugin: "ruby", family: :ecosystem, provider: "Ruby::Ecosystem",
      extension_point: :ecosystem, operation: :detect_prepare, exception: error,
      count: 2, last_at: Time.zone.at(1)
    )

    expect(conformance).to have_attributes(
      source: :conformance, code: :missing_capability, extension_point: nil, operation: nil, count: 1
    )
    expect(runtime).to have_attributes(
      source: :runtime, family: :ecosystem, provider: "Ruby::Ecosystem", code: :runtime_failure,
      extension_point: "ecosystem", operation: "detect_prepare", exception_class: "RuntimeError",
      message: "detector failed", backtrace: [ "plugin.rb:1" ], count: 2
    )
    expect(Syrus::Plugin::Conformance::Finding).to equal(described_class::Finding)
    expect(Syrus::PluginRuntimeHealth::Failure).to equal(described_class::Finding)
  end

  def manifest(name, depends_on: [], conflicts_with: [], optionally_depends_on: [])
    Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: name, version: "1.0.0", provides: {}, metadata: {},
      depends_on: depends_on, conflicts_with: conflicts_with,
      optionally_depends_on: optionally_depends_on
    )
  end

  def external_manifest(scan:, requires_syrus: nil)
    Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, name: "external", version: "1.0.0", provides: {}, external: true,
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

  # Regression (formal/SyrusModel/PluginClosure.lean): a contribution is
  # callable only when the whole required dependency closure is healthy.
  # Only direct dependencies were checked, and only for being enabled, so a
  # plugin stayed healthy on top of a hard dependency that was itself
  # degraded and whose providers were withheld.
  it "degrades a plugin whose enabled hard dependency is itself unhealthy" do
    manifests = [ manifest("c"), manifest("b", depends_on: [ "c" ]), manifest("a", depends_on: [ "b" ]) ]
    subject = health(manifests, enabled: %w[a b])

    expect(subject.status("b").state).to eq(:degraded)
    expect(subject.status("a").state).to eq(:degraded)
    expect(subject.status("a").reasons).to include("requires b, which is degraded")
    expect(subject.healthy?("a")).to be(false)
  end

  it "degrades every plugin above an unhealthy one along a dependency chain" do
    manifests = [ manifest("d", depends_on: [ "missing" ]), manifest("c", depends_on: [ "d" ]),
                  manifest("b", depends_on: [ "c" ]), manifest("a", depends_on: [ "b" ]) ]
    subject = health(manifests)

    expect(%w[a b c d].map { |name| subject.healthy?(name) }).to all(be(false))
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

  # DOC-44: optional dependency absence cannot disable the dependent plugin.
  # Unhealthy propagation follows hard edges only.
  it "leaves a plugin ok when an optional dependency is disabled or unhealthy" do
    manifests = [ manifest("c"), manifest("b", depends_on: [ "c" ]),
                  manifest("chat", optionally_depends_on: [ "b", "off" ]), manifest("off") ]
    subject = health(manifests, enabled: %w[b chat])

    expect(subject.status("b").state).to eq(:degraded)
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
