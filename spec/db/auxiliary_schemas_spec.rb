require "rails_helper"

RSpec.describe "auxiliary database schemas" do
  it "uses Rails-supported binary limits instead of MySQL dump-only size options" do
    %w[ db/cache_schema.rb db/cable_schema.rb ].each do |path|
      schema = Rails.root.join(path).read

      expect(schema).not_to include("size: :long")
      expect(schema).to include("limit: 536870912")
    end
  end
end
