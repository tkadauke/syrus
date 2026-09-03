require "rails_helper"

RSpec.describe Syrus::PluginHealth do
  def manifest(name, depends_on: [], conflicts_with: [], optionally_depends_on: [])
    Syrus::Plugin::Manifest.new(
      name: name, version: "1.0.0", provides: {}, metadata: {},
      depends_on: depends_on, conflicts_with: conflicts_with,
      optionally_depends_on: optionally_depends_on
    )
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
end
