require "rails_helper"

RSpec.describe Filters::BaseFilter do
  # Minimal concrete class to exercise the shared behaviour without
  # coupling the spec to any subject-specific filter (Jobs, Epics, …).
  let(:concrete_filter_class) do
    Class.new do
      include Filters::BaseFilter

      def initialize(tree, user: nil)
        @ast = Filters::Ast.parse(tree)
        @user = user
      end

      def apply(scope)
        scope
      end
    end
  end

  def filter_for(tree)
    concrete_filter_class.new(tree)
  end

  def chip(field, op, value)
    { "field" => field, "op" => op, "value" => value }
  end

  describe ".from_tree" do
    it "constructs a filter from a raw hash tree" do
      tree = { "and" => [ chip("state", "is", "open") ] }
      f = concrete_filter_class.from_tree(tree)
      expect(f.to_h).to eq(tree)
    end

    it "accepts user: kwarg" do
      user = Factories.user
      tree = { "and" => [ chip("state", "is", "open") ] }
      f = concrete_filter_class.from_tree(tree, user: user)
      expect(f.to_h).to eq(tree)
    end
  end

  describe "#to_h" do
    it "round-trips an AST tree through Filters::Ast" do
      tree = { "and" => [ chip("state", "is", "open"), chip("kind", "is", "issue") ] }
      expect(filter_for(tree).to_h).to eq(tree)
    end
  end

  describe "#to_query_param" do
    it "produces a base64-encoded representation that Filters::QueryParam can decode" do
      tree = { "and" => [ chip("state", "is", "open") ] }
      f = filter_for(tree)
      decoded = Filters::QueryParam.decode(f.to_query_param)
      expect(decoded).to eq(tree)
    end
  end

  describe "#active?" do
    it "returns false for an empty tree" do
      empty = Filters::Ast.serialize(Filters::Ast::EMPTY)
      expect(filter_for(empty).active?).to be false
    end

    it "returns true when the tree contains at least one chip" do
      tree = { "and" => [ chip("state", "is", "open") ] }
      expect(filter_for(tree).active?).to be true
    end

    it "returns true for chips nested inside OR nodes" do
      tree = { "or" => [ chip("state", "is", "open"), chip("state", "is", "closed") ] }
      expect(filter_for(tree).active?).to be true
    end

    it "returns true for chips nested inside NOT nodes" do
      tree = { "not" => chip("state", "is", "closed") }
      expect(filter_for(tree).active?).to be true
    end
  end

  describe ".merge_and (private)" do
    it "combines two flat trees into a single AND node" do
      left  = { "and" => [ chip("state", "is", "open") ] }
      right = { "and" => [ chip("kind", "is", "issue") ] }
      result = concrete_filter_class.send(:merge_and, left, right)
      expect(result["and"].length).to eq(2)
    end

    it "flattens nested AND-of-AND into a single level" do
      left  = { "and" => [ chip("state", "is", "open"), chip("kind", "is", "issue") ] }
      right = { "and" => [ chip("repository_id", "is", "42") ] }
      result = concrete_filter_class.send(:merge_and, left, right)
      expect(result["and"].length).to eq(3)
    end

    it "wraps a non-AND left node in the children array" do
      left  = chip("state", "is", "open")
      right = { "and" => [ chip("kind", "is", "issue") ] }
      result = concrete_filter_class.send(:merge_and, left, right)
      expect(result["and"]).to include(left, chip("kind", "is", "issue"))
    end
  end

  describe ".chip (private)" do
    it "builds a chip hash with field, op, and value" do
      result = concrete_filter_class.send(:chip, "state", "is", "open")
      expect(result).to eq({ "field" => "state", "op" => "is", "value" => "open" })
    end

    it "omits the value key when value is nil" do
      result = concrete_filter_class.send(:chip, "published", "is_true", nil)
      expect(result).to eq({ "field" => "published", "op" => "is_true" })
      expect(result).not_to have_key("value")
    end
  end
end
