# MySQL's REPEATABLE READ pins every plain read in a transaction to the
# snapshot taken at its first plain read. Lineage.lock! makes such reads while
# it collects a record's ancestry, before it waits on the row locks, so a plain
# `reload` afterwards can answer with rows as they were before a concurrent
# transaction committed. Locking reads (`reload(lock: true)`, `.lock.find`)
# always see the latest committed row.
#
# SQLite has no such snapshot. This stages it for the given models: a plain
# `reload` keeps the in-memory copy (the snapshot's answer), a locking one
# reads the row.
module RepeatableReadSnapshot
  def stage_repeatable_read_snapshot!(*models)
    models.each do |model|
      allow_any_instance_of(model).to receive(:reload).and_wrap_original do |original, *args, **kwargs|
        kwargs[:lock] ? original.call(*args, **kwargs) : original.receiver
      end
    end
  end
end

RSpec.configure { |config| config.include RepeatableReadSnapshot }
