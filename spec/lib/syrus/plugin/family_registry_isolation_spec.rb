require "rails_helper"

# Regression: an example that reset the family registry to built-ins dropped
# the families plugins define at load time (mail, personal_calendar) for the
# rest of the process, so the generated plugin spec, and the shard that ran
# its freshness check, depended on spec order.
RSpec.describe Syrus::Plugin::Family, ".snapshot / .restore_snapshot!" do
  it "puts plugin-defined families back after a reset to built-ins" do
    before = described_class.all.map(&:name)
    snapshot = described_class.snapshot

    described_class.restore_built_ins!
    expect(described_class.all.map(&:name)).not_to include(:mail)
    described_class.restore_snapshot!(snapshot)

    expect(described_class.all.map(&:name)).to match_array(before)
    expect(before).to include(:mail, :personal_calendar)
  end
end
