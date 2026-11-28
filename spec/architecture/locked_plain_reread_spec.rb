require "rails_helper"
require "prism"

# A plain read after a row lock can return the row as it was before the lock
# was granted. MySQL's primary database runs at REPEATABLE READ: a
# transaction's plain SELECTs answer from the snapshot its first plain read
# fixed, and Lineage.lock! makes plain discovery reads before it waits on the
# locks. A `reload` after the lock then hands the caller the pre-lock row --
# in production a Run was claimed twice that way, because the second
# perform's reload still read it as queued. A locking read
# (`reload(lock: true)`, `Model.lock.find`) returns the latest committed row.
#
# SQLite has no snapshot, so no example can fail on it; this check is the
# guard. It flags a plain `reload` that follows a row lock in the same method
# (inside the same transaction block when the lock is in one), and any plain
# `reload` inside an `aasm` block, whose events lock their lineage first.
# A plain `reload` after a with_lock that opens the outermost transaction is
# safe -- its lock! is the transaction's first read, so the snapshot comes
# after the lock -- but a with_lock can be called inside an outer
# transaction, so such sites are reviewed and listed below rather than
# exempted by shape.
#
# The detector only sees `reload`. Association reads, `find`, `exists?` and
# `count` after a lock have the same exposure and are reviewed by hand; see
# docs/engineering/pitfalls/queues-databases-and-polling.md.
RSpec.describe "Plain re-reads after a row lock" do
  SOURCE_GLOBS = %w[app/**/*.rb lib/**/*.rb plugins/*/app/**/*.rb plugins/*/lib/**/*.rb].freeze
  LINEAGE_LOCKS = %w[lock! lock_all! lock_active_work! lock_subtree!].freeze
  TRANSACTION_BLOCKS = %w[transaction with_lock].freeze

  # "path#method: receiver.reload" => why a plain read is right there.
  # Reviewed sites only: each says why the snapshot cannot hide a change the
  # decision depends on.
  REVIEWED = {
    "app/services/work_engine/repair_executor.rb#perform: workflow.job.reload" =>
      "a Job lock after the WorkUnit would invert the row-lock order (NY40); the read only lists the urgent " \
        "Jobs blocking a landing slot, and the reconciler re-evaluates it on every pass",
    "app/services/landing_queue_processor.rb#release_urgent_blocked_landing_slots_for_urgent_job!: workflow.job.reload" =>
      "a Job lock after the WorkUnit would invert the row-lock order (NY40); the read only lists the urgent " \
        "Jobs blocking a landing slot, and the dispatcher re-evaluates it on every pass",
    "app/services/chat_epic_proposal_materializer.rb#file!: epic.dependencies.reload" =>
      "an association reload of rows this transaction just inserted, which every read in it sees",
    "plugins/design_docs/app/services/design_docs/create_suggestion.rb#call: design_doc.reload" =>
      "builds the response from this transaction's own writes, after every decision is made",
    "plugins/design_docs/app/services/design_docs/create_suggestion.rb#call: suggestion.reload" =>
      "builds the response from the row this transaction just inserted"
  }.freeze

  def self.sources
    SOURCE_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob)] }.reject { |path| path.include?("/spec/") }.sort
  end

  def self.call_nodes(node, found = [])
    return found unless node.is_a?(Prism::Node)

    found << node if node.is_a?(Prism::CallNode)
    node.compact_child_nodes.each { |child| call_nodes(child, found) }
    found
  end

  def self.lock_argument?(call)
    Array(call.arguments&.arguments).any? do |argument|
      argument.is_a?(Prism::KeywordHashNode) &&
        argument.elements.any? { |element| element.key.is_a?(Prism::SymbolNode) && element.key.unescaped == "lock" }
    end
  end

  def self.row_lock?(call)
    name = call.name.to_s
    receiver = call.receiver
    return true if LINEAGE_LOCKS.include?(name) && receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Lineage
    return true if name.in?(%w[lock_event_lineage! with_lock lock!])
    return true if name == "lock" && receiver
    name == "reload" && lock_argument?(call)
  end

  def self.plain_reload?(call)
    call.name == :reload && !lock_argument?(call)
  end

  def self.within?(inner, outer)
    inner.location.start_offset >= outer.location.start_offset && inner.location.end_offset <= outer.location.end_offset
  end

  # The innermost transaction-opening block call (transaction/with_lock)
  # around +call+ inside the scope, or nil.
  def self.enclosing_transaction(call, calls)
    calls.select { |candidate| candidate.block && TRANSACTION_BLOCKS.include?(candidate.name.to_s) && candidate != call && within?(call, candidate) }
      .min_by { |candidate| candidate.location.end_offset - candidate.location.start_offset }
  end

  def self.scopes(tree, found = [])
    return found unless tree.is_a?(Prism::Node)

    found << [ tree.name.to_s, tree, false ] if tree.is_a?(Prism::DefNode)
    found << [ "aasm", tree.block, true ] if tree.is_a?(Prism::CallNode) && tree.name == :aasm && tree.block
    tree.compact_child_nodes.each { |child| scopes(child, found) }
    found
  end

  # +files+: relative path => source.
  def self.findings(files = sources.to_h { |path| [ Pathname(path).relative_path_from(Rails.root).to_s, File.read(path) ] })
    files.flat_map do |relative, source|
      scopes(Prism.parse(source).value).flat_map do |name, scope, locks_on_entry|
        calls = call_nodes(scope.respond_to?(:body) && scope.is_a?(Prism::DefNode) ? scope.body : scope)
          .sort_by { |call| call.location.start_offset }
        locks = calls.select { |call| row_lock?(call) }
        calls.filter_map do |call|
          next unless plain_reload?(call)

          exposed = locks_on_entry || locks.any? do |lock|
            next false unless lock.location.start_offset < call.location.start_offset || (lock.block && within?(call, lock))

            transaction = lock.block && lock.name.to_s == "with_lock" ? lock : enclosing_transaction(lock, calls)
            transaction.nil? || within?(call, transaction)
          end
          next unless exposed

          {
            key: "#{relative}##{name}: #{call.slice.lines.first.strip}",
            site: "#{relative}:#{call.location.start_line}"
          }
        end
      end
    end
  end

  it "re-reads locked rows with locking reads" do
    unreviewed = self.class.findings.reject { |finding| REVIEWED.key?(finding[:key]) }

    expect(unreviewed).to be_empty, <<~MSG
      A plain `reload` after a row lock in the same transaction can return the row as it was before the
      lock was granted (MySQL REPEATABLE READ). Use `reload(lock: true)` -- it is free for a row this
      transaction already holds -- or, if the plain read is right, add the site to REVIEWED with the reason:
        #{unreviewed.map { |finding| "#{finding[:site]}  #{finding[:key]}" }.join("\n  ")}
    MSG
  end

  it "keeps no reviewed entry for a site that no longer exists" do
    keys = self.class.findings.map { |finding| finding[:key] }

    expect(REVIEWED.keys - keys).to be_empty
  end

  it "actually finds plain re-reads after a lock, so a parser change cannot quietly empty this check" do
    source = <<~RUBY
      def claim!(run)
        Run.transaction do
          Lineage.lock!(run)
          run.reload
        end
        run.reload
      end

      def fine!(run)
        Run.transaction do
          Lineage.lock!(run)
          run.reload(lock: true)
        end
      end
    RUBY

    expect(self.class.findings("example.rb" => source).map { |finding| finding[:key] }).to eq([ "example.rb#claim!: run.reload" ])
  end
end
