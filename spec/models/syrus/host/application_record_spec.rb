require "rails_helper"

RSpec.describe Syrus::Host::ApplicationRecord do
  it "is an abstract stable base for plugin-owned records" do
    plugin_record_class = Class.new(described_class)
    plugin_record_class.table_name = "example_plugin_records"

    expect(described_class).to be_abstract_class
    expect(plugin_record_class).to be < ApplicationRecord
    expect(plugin_record_class.table_name).to eq("example_plugin_records")
  end
end
