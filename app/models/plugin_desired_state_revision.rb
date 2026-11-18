class PluginDesiredStateRevision < ApplicationRecord
  validates :singleton_key, inclusion: { in: [ 1 ] }, uniqueness: true

  def self.publish_next!
    state = find_or_create_by!(singleton_key: 1) { |record| record.revision = 0 }
    state.with_lock do
      revision = state.revision + 1
      result = yield revision
      state.update!(revision: revision)
      result
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def self.current
    find_by(singleton_key: 1)&.revision.to_i
  end
end
