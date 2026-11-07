require "rails_helper"

RSpec.describe "documentation audiences" do
  it "documents each maintainer audience in the docs index" do
    index = Rails.root.join("docs/README.md").read

    %w[dev internals ops plugins].each do |section|
      expect(Rails.root.join("docs", section, "README.md")).to exist
      expect(index).to include("[`#{section}/`](#{section}/)")
    end
  end

  it "keeps the cross-project searchable-doc rule in agent guidance" do
    guidance = Rails.root.join("CLAUDE.md").read

    expect(guidance).to include("searchable by chat and implementation agents working on any project")
    expect(guidance).to include("Internal-only changes")
    expect(guidance).to include("docs/dev/")
    expect(guidance).to include("docs/internals/")
    expect(guidance).to include("docs/ops/")
    expect(guidance).to include("docs/plugins/")
  end

  it "does not make searchable harness docs mandatory for internal-only changes" do
    workflow_config = Rails.root.join(".syrus.yml").read

    expect(workflow_config).to include("Do not require searchable\n      harness docs for internal-only implementation changes")
  end
end
