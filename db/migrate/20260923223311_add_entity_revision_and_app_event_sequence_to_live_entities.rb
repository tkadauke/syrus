class AddEntityRevisionAndAppEventSequenceToLiveEntities < ActiveRecord::Migration[8.1]
  REVISIONED_TABLES = %i[jobs workflows steps runs chat_sessions chat_messages].freeze

  def up
    REVISIONED_TABLES.each do |table|
      next if column_exists?(table, :entity_revision)

      add_column table, :entity_revision, :bigint, default: 0, null: false
    end

    unless column_exists?(:users, :app_event_sequence)
      add_column :users, :app_event_sequence, :bigint, default: 0, null: false
    end
  end

  def down
    REVISIONED_TABLES.each do |table|
      remove_column table, :entity_revision if column_exists?(table, :entity_revision)
    end

    remove_column :users, :app_event_sequence if column_exists?(:users, :app_event_sequence)
  end
end
