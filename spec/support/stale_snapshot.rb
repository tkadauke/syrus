# Stages MySQL REPEATABLE READ's stale snapshot, which SQLite cannot produce.
#
# Inside a transaction whose snapshot was fixed before it waited on a row
# lock, plain reads answer as of the snapshot, while locking reads
# (`.lock`, `reload(lock: true)`) return the latest committed rows. Under
# `with_stale_snapshot(Run => [ids])`, plain `exists?`, `count` and
# `first`/`last` on that model's relations see only the listed rows -- the
# rows the snapshot holds -- while relations with a lock see the table as it
# is. A spec then shows that a decision made after a lock reads through a
# locking read: with a plain read it would answer from the staged snapshot.
#
# For a stale *row*, see spec/jobs/run_job_duplicate_execution_spec.rb:
# stub the record's plain reload to keep its in-memory copy.
module StaleSnapshot
  module RelationReads
    %i[exists? count first last].each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        visible = StaleSnapshot.visible_ids_for(klass)
        return super(*args, **kwargs, &block) if visible.nil? || lock_value

        StaleSnapshot.without_staging { where(id: visible).public_send(method_name, *args, **kwargs, &block) }
      end
    end
  end

  def self.visible_ids_for(klass)
    staged = Thread.current[:stale_snapshot_ids]
    return nil if staged.nil?

    staged.each { |model, ids| return ids if klass <= model }
    nil
  end

  def self.without_staging
    staged = Thread.current[:stale_snapshot_ids]
    Thread.current[:stale_snapshot_ids] = nil
    yield
  ensure
    Thread.current[:stale_snapshot_ids] = staged
  end

  module Helpers
    def with_stale_snapshot(ids_by_model)
      previous = Thread.current[:stale_snapshot_ids]
      Thread.current[:stale_snapshot_ids] = ids_by_model.transform_values { |ids| Array(ids) }
      yield
    ensure
      Thread.current[:stale_snapshot_ids] = previous
    end

    # Keeps +record+'s in-memory copy on a plain reload, as a REPEATABLE READ
    # snapshot taken before the row changed would; a locking reload still
    # reads the row.
    def pin_plain_reload(record)
      allow(record).to receive(:reload).and_wrap_original do |original, *args, **kwargs|
        kwargs[:lock] ? original.call(*args, **kwargs) : record
      end
    end
  end
end

ActiveRecord::Relation.prepend(StaleSnapshot::RelationReads)

RSpec.configure do |config|
  config.include StaleSnapshot::Helpers
end
