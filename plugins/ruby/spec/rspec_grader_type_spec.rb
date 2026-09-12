require "rails_helper"

RSpec.describe Ruby::RspecGraderType do
  it "registers the rspec type name" do
    expect(described_class.type_name).to eq("rspec")
  end

  it "expands to focused review and full landing/ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[rspec rspec-focused])
    expect(steps.first.run).to eq("bundle exec rspec")
    expect(steps.first.phases).to eq(%w[landing ci])
    expect(steps.first.failures).to eq("allow_inherited")
    expect(steps.first.base_retry).to eq(SyrusYml::BaseRetry.new(strategy: "plugin", command: nil))

    expect(steps.second.run).to include('exec("bundle", "exec", "rspec"')
    expect(steps.second.phases).to eq(%w[review])
    expect(steps.second.when_files_changed).to eq([ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ])
  end

  it "allows a custom name prefix and inherited-failure policy" do
    steps = described_class.grade_steps(
      config: { "name" => "ruby-specs", "failures" => "allow_inherited", "required" => false, "timeout_minutes" => 30 },
      default_failures: "strict"
    )

    expect(steps.map(&:name)).to eq(%w[ruby-specs ruby-specs-focused])
    expect(steps.map(&:failures)).to eq(%w[allow_inherited allow_inherited])
    expect(steps.map(&:required)).to eq([ false, false ])
    expect(steps.map(&:timeout_minutes)).to eq([ 30, 30 ])
  end
end
