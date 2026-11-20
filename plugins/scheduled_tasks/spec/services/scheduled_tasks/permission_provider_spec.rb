require "rails_helper"

RSpec.describe ScheduledTasks::PermissionProvider do
  def descriptor(operation) = described_class.capability_descriptor("scheduled_tasks/#{operation}@v1")

  it "keeps observation and pausing automatic" do
    %w[list read pause].each do |operation|
      expect(descriptor(operation).defaults.values.uniq).to eq([ :allow ])
      expect(descriptor(operation).classify({})[:risk]).to eq(:low)
    end
  end

  it "asks before adding or changing persistent autonomy" do
    %w[create update resume fire_now].each do |operation|
      expect(descriptor(operation).defaults.values.uniq).to eq([ :ask ])
      expect(descriptor(operation).classify({})[:effects]).to include(:persistent_autonomy)
    end
  end

  it "asks for every autonomy change while letting the operator allow it forever" do
    %w[create update resume fire_now delete].each do |name|
      expect(descriptor(name)).to have_attributes(maximum_autonomy: :permanent, essential: false)
      expect(descriptor(name).defaults.values.uniq).to eq([ :ask ])
    end
    # Observing and pausing never add autonomy: they are essential.
    expect(%w[list read pause].map { |name| descriptor(name).essential? }.uniq).to eq([ true ])
    expect(descriptor("delete").classify({})[:effects]).to include(:destructive)
  end

  it "fingerprints exact arguments and ignores omitted optionals" do
    create = descriptor("create")

    expect(create.normalize_fingerprint(label: "a", prompt: "p", schedule_input: nil)).to eq(create.normalize_fingerprint("prompt" => "p", "label" => "a"))
    expect(create.normalize_fingerprint(label: "a", prompt: "p")).not_to eq(create.normalize_fingerprint(label: "a", prompt: "q"))
  end

  it "attaches an explicit descriptor to every chat tool" do
    definitions = ScheduledTasks::ChatToolSet.tool_definitions(tier: :deferred)

    expect(definitions.map { |d| d.fetch(:name) }).to match_array(ScheduledTasks::ChatToolSet::DESCRIPTORS.keys)
    expect(definitions.map { |d| d.fetch(:capability_descriptor).operation }.uniq.size).to eq(definitions.size)
  end

  it "raises no registry findings for the scheduled task tools" do
    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    mine = findings.select { |f| f.registrations.any? { |r| ScheduledTasks::ChatToolSet::DESCRIPTORS.key?(r.tool_name) } }

    expect(mine).to be_empty
  end
end
