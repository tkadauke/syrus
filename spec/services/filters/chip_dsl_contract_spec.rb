require "rails_helper"

RSpec.describe "Filters::Chips DSL contract" do
  Filters::Registry::CHIPS.each do |field, class_name|
    describe class_name do
      subject(:chip_class) { class_name.constantize }

      it "loads as a Filters::Chips::Base subclass" do
        expect(chip_class).to be < Filters::Chips::Base
      end

      it "declares the registered filter name" do
        expect(chip_class.filter_name).to eq(field)
      end

      it "declares a bucket" do
        expect(chip_class.bucket).to be_present
      end

      it "declares at least one operator" do
        expect(chip_class.operators).to all(be_a(Symbol))
        expect(chip_class.operators).to be_present
      end

      it "implements apply without falling back to Base#apply" do
        expect(chip_class.method_defined?(:apply)).to be(true)
        expect(chip_class.instance_method(:apply).owner).not_to eq(Filters::Chips::Base)
      end
    end
  end
end
