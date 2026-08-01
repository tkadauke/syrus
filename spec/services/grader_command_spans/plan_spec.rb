require "rails_helper"

RSpec.describe GraderCommandSpans::Plan do
  it "splits common composite grader commands into readable phases" do
    plan = described_class.for("bundle check || bundle install && bin/rails db:test:prepare && bin/rspec")

    expect(plan).to be_instrumentable
    expect(plan.fragments.map(&:name)).to eq([ "bundle check", "bundle install", "db:test:prepare", "rspec" ])
    expect(plan.fragments.map(&:operator_before)).to eq([ nil, "||", "&&", "&&" ])
  end

  it "falls back to one span for commands without top-level phases" do
    plan = described_class.for("bin/rspec spec/models")

    expect(plan).not_to be_instrumentable
    expect(plan.fallback_reason).to eq("no top-level shell operators")
    expect(plan.fragments.first.name).to eq("rspec")
  end

  it "does not split operators inside quotes" do
    plan = described_class.for("ruby -e 'puts \"a && b\"' && npm run test:react")

    expect(plan.fragments.map(&:command)).to eq([ "ruby -e 'puts \"a && b\"'", "npm run test:react" ])
    expect(plan.fragments.map(&:name)).to eq([ "ruby -e 'puts #1", "frontend tests" ])
  end

  it "falls back for shell control flow instead of splitting internal semicolons" do
    plan = described_class.for("if bundle check; then bin/rspec; else bundle install && bin/rspec; fi")

    expect(plan).not_to be_instrumentable
    expect(plan.fallback_reason).to eq("contains shell control flow")
  end
end
