# frozen_string_literal: true

require "spec_helper"

RSpec.describe "bin/check-fresh-production-db-prepare" do
  subject(:script) { File.read(File.expand_path("../../bin/check-fresh-production-db-prepare", __dir__)) }

  it "boots with disposable encryption keys instead of embedding Rails credentials" do
    expect(script).to include("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
    expect(script).to include("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
    expect(script).to include("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
    expect(script).not_to include("RAILS_MASTER_KEY")
    expect(script).not_to match(/\b[0-9a-f]{32}\b/)
  end
end
