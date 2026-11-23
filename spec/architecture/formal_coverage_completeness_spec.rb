require "rails_helper"
require "json"
require "prism"

# Inventory completeness (formal/INTEGRATION.md, layer 5): every issue kind the
# reconciler can emit has an entry in formal/coverage/coverage.json, so adding a
# repair forces the question "can we prevent this instead?". And every kind the
# inventory names can still be emitted, so a retired kind does not linger.
#
# Kinds are collected with Prism from WorkEngine::Reconciler: the symbols in the
# `kind:` argument of every `issue(...)` call, and, when that argument calls a
# helper the reconciler defines (start_block_issue_kind), the symbols the
# helper returns. A literal-only scan misses both the ternaries and the helpers.
RSpec.describe "Formal coverage inventory completeness" do
  RECONCILER = Rails.root.join("app/services/work_engine/reconciler.rb")

  def symbols_in(node, found = [])
    return found unless node.is_a?(Prism::Node)

    # A keyword or hash key (`dependency_block:`) is a label, not a value.
    return symbols_in(node.value, found) if node.is_a?(Prism::AssocNode)

    found << node.unescaped if node.is_a?(Prism::SymbolNode)
    node.compact_child_nodes.each { |child| symbols_in(child, found) }
    found
  end

  def each_node(node, &block)
    return unless node.is_a?(Prism::Node)

    yield node
    node.compact_child_nodes.each { |child| each_node(child, &block) }
  end

  def emitted_issue_kinds
    tree = Prism.parse(RECONCILER.read).value
    helpers = {}
    each_node(tree) { |node| helpers[node.name] = node if node.is_a?(Prism::DefNode) }

    kinds = []
    each_node(tree) do |node|
      next unless node.is_a?(Prism::CallNode) && node.name == :issue && node.receiver.nil?

      elements = node.arguments&.arguments&.grep(Prism::KeywordHashNode)&.flat_map(&:elements) || []
      elements.each do |element|
        case element
        when Prism::AssocNode
          next unless kind_key?(element)

          kinds.concat(kind_symbols(element.value, helpers))
        when Prism::AssocSplatNode
          # issue(**some_issue(...)): the helper builds the hash, kind: included.
          called_helpers(element.value, helpers).each do |helper|
            each_node(helper.body) { |pair| kinds.concat(kind_symbols(pair.value, helpers)) if pair.is_a?(Prism::AssocNode) && kind_key?(pair) }
          end
        end
      end
    end
    kinds.uniq.sort
  end

  def kind_key?(pair) = pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == "kind"

  def called_helpers(node, helpers)
    found = []
    each_node(node) { |call| found << helpers[call.name] if call.is_a?(Prism::CallNode) && helpers.key?(call.name) }
    found
  end

  # The symbols a `kind:` value can produce: its own, and those the reconciler
  # helpers it calls return.
  def kind_symbols(value, helpers)
    symbols_in(value) + called_helpers(value, helpers).flat_map { |helper| symbols_in(helper.body) }
  end

  def inventoried_issue_kinds
    JSON.parse(Rails.root.join("formal/coverage/coverage.json").read).fetch("items")
      .flat_map { |item| Array(item["issue_kinds"]) }.uniq.sort
  end

  it "finds the reconciler's issue kinds (guards against the scan matching nothing)" do
    expect(emitted_issue_kinds.size).to be >= 70
    expect(emitted_issue_kinds).to include("queued_run_before_required_review_barrier", "serialized_start_block")
  end

  it "has an inventory entry for every issue kind the reconciler can emit" do
    missing = emitted_issue_kinds - inventoried_issue_kinds

    expect(missing).to be_empty, <<~MESSAGE
      These reconciler issue kinds have no entry in formal/coverage/coverage.json: #{missing.join(', ')}.
      Add an item naming each in "issue_kinds", with a status: can the state be proved unreachable
      instead of repaired? (formal/INTEGRATION.md, layer 5)
    MESSAGE
  end

  it "names no issue kind the reconciler can no longer emit" do
    stale = inventoried_issue_kinds - emitted_issue_kinds

    expect(stale).to be_empty, "formal/coverage/coverage.json names issue kinds the reconciler no longer emits: #{stale.join(', ')}"
  end
end
