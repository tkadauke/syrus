require "rails_helper"

RSpec.describe "main branch breakage policy operator docs" do
  it "document the policy, values, inherited-failure gate, and explicit resume path" do
    docs = %w[
      config/syrus_docs/app_settings.md
      config/syrus_docs/landing_queue.md
    ].map { |path| Rails.root.join(path).read }.join("\n")

    # Keep this contract on operator-visible policy rather than internal Ruby
    # accessors, jobs, or controller actions. Searchable harness docs describe
    # how the setting behaves, while implementation details belong in the
    # engineering hierarchy.
    expect(docs).to include("Repository risk posture")
    expect(docs).to include("strict")
    expect(docs).to include("Isolation policy")
    expect(docs).to include("inherited grader failures")
    expect(docs).to include("`pr_check_gate`")
    expect(docs).to include("`all`, `own_only`, or `none`")
    expect(docs).to include("**Resume landing**")
    expect(docs).to include("main repair")
  end
end
