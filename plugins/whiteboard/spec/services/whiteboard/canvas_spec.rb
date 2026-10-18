require "rails_helper"

RSpec.describe Whiteboard::Canvas do
  describe ".connector_point" do
    subject(:point) { described_class.connector_point(element, toward: toward) }

    let(:type) { "rectangle" }
    let(:element) { { "type" => type, "x" => 10, "y" => 20, "width" => 100, "height" => 60, "angle" => 0 } }
    let(:toward) { { "x" => 210, "y" => 50 } }

    %w[rectangle ellipse diamond].each do |shape_type|
      context "with a #{shape_type}" do
        let(:type) { shape_type }

      it "anchors on the shape's right edge" do
          expect(point.fetch("x")).to be_within(0.0001).of(110.0)
          expect(point.fetch("y")).to be_within(0.0001).of(50.0)
        end
      end
    end

    it "uses the ellipse outline for diagonal connections" do
      element["type"] = "ellipse"
      diagonal = described_class.connector_point(element, toward: { "x" => 160, "y" => 110 })

      normalized = ((diagonal.fetch("x") - 60) / 50.0)**2 + ((diagonal.fetch("y") - 50) / 30.0)**2
      expect(normalized).to be_within(0.0001).of(1.0)
    end

    it "uses the diamond outline for diagonal connections" do
      element["type"] = "diamond"
      diagonal = described_class.connector_point(element, toward: { "x" => 160, "y" => 110 })

      normalized = (diagonal.fetch("x") - 60).abs / 50.0 + (diagonal.fetch("y") - 50).abs / 30.0
      expect(normalized).to be_within(0.0001).of(1.0)
    end

    it "falls back to the center for rotated or unsupported elements" do
      expect(described_class.connector_point(element.merge("angle" => 0.25), toward: toward)).to eq("x" => 60.0, "y" => 50.0)
      expect(described_class.connector_point(element.merge("type" => "image"), toward: toward)).to eq("x" => 60.0, "y" => 50.0)
    end
  end
end
