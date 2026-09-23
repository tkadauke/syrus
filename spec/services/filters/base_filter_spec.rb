require "rails_helper"

RSpec.describe Filters::BaseFilter do
  # Minimal concrete class to exercise the shared behaviour without
  # coupling the spec to any subject-specific filter (Jobs, Epics, …).
  let(:concrete_filter_class) do
    Class.new do
      include Filters::BaseFilter

      def self.build_tree_from_url_params(params)
        return nil unless params[:state].present?

        { "and" => [ { "field" => "state", "op" => "is", "value" => params[:state] } ] }
      end

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

  describe ".capped_count" do
    # Simulates SQL's LIMIT: .limit(n) narrows what a later .pluck(:id) returns,
    # so the double behaves like a real scope instead of always plucking every id.
    def scope_returning(ids)
      scope = instance_double(ActiveRecord::Relation)
      limited = ids
      allow(scope).to receive(:reselect).with(:id).and_return(scope)
      allow(scope).to receive(:limit) { |n| limited = ids.first(n); scope }
      allow(scope).to receive(:pluck).with(:id) { limited }
      scope
    end

    it "stops scanning at limit + 1 rows regardless of true match count" do
      scope = scope_returning([ 1, 2, 3, 4, 5 ])

      Filters::BaseFilter.capped_count(scope, limit: 2)

      expect(scope).to have_received(:limit).with(3)
    end

    it "defaults the scan window to SmartFolder::COUNT_CAP + 1" do
      scope = scope_returning([])

      Filters::BaseFilter.capped_count(scope)

      expect(scope).to have_received(:limit).with(SmartFolder::COUNT_CAP + 1)
    end

    it "returns the exact count when it is below the limit" do
      scope = scope_returning([ 1, 2 ])

      expect(Filters::BaseFilter.capped_count(scope, limit: 5)).to eq(2)
    end

    it "clamps the result at the limit when the true count meets it" do
      scope = scope_returning([ 1, 2 ])

      expect(Filters::BaseFilter.capped_count(scope, limit: 2)).to eq(2)
    end

    it "clamps the result at the limit when the true count exceeds it" do
      scope = scope_returning([ 1, 2, 3 ])

      expect(Filters::BaseFilter.capped_count(scope, limit: 2)).to eq(2)
    end

    it "is usable as an instance method by any including class" do
      Factories.job_record(issue_number: 1)
      Factories.job_record(issue_number: 2)

      expect(filter_for({ "and" => [] }).capped_count(Job.all, limit: 1)).to eq(1)
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

  describe ".smart_folder_floor" do
    let(:smart_folder) { Struct.new(:filter).new({ "and" => [ chip("state", "is", "open") ] }) }

    it "returns nil when there is no smart folder to guard" do
      result = concrete_filter_class.smart_folder_floor({}, nil)
      expect(result).to be_nil
    end

    it "keeps the smart folder when the request carries no ad hoc filter at all" do
      result = concrete_filter_class.smart_folder_floor({}, smart_folder)
      expect(result).to eq(smart_folder)
    end

    it "drops the smart folder once legacy URL params make the ad hoc filter active" do
      result = concrete_filter_class.smart_folder_floor({ state: "closed" }, smart_folder)
      expect(result).to be_nil
    end

    it "drops the smart folder when q= carries chips" do
      q = Filters::QueryParam.encode("and" => [ chip("kind", "is", "issue") ])
      result = concrete_filter_class.smart_folder_floor({ q: q }, smart_folder)
      expect(result).to be_nil
    end

    it "drops the smart folder when q= is present but decodes to zero chips" do
      q = Filters::QueryParam.encode("and" => [])
      result = concrete_filter_class.smart_folder_floor({ q: q }, smart_folder)
      expect(result).to be_nil
    end

    it "drops the smart folder when q= is present as a string key" do
      q = Filters::QueryParam.encode("and" => [])
      result = concrete_filter_class.smart_folder_floor({ "q" => q }, smart_folder)
      expect(result).to be_nil
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
