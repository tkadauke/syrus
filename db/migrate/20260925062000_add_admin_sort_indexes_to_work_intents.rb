class AddAdminSortIndexesToWorkIntents < ActiveRecord::Migration[8.1]
  INDEXES = {
    "idx_work_intents_admin_requested" => [ :requested_at, :id ],
    "idx_work_intents_admin_kind" => [ :kind, :requested_at, :id ],
    "idx_work_intents_admin_state" => [ :state, :requested_at, :id ],
    "idx_work_intents_admin_scope" => [ :scope_type, :scope_id, :requested_at, :id ],
    "idx_work_intents_admin_repository" => [ :repository_id, :requested_at, :id ]
  }.freeze

  def up
    INDEXES.each do |name, columns|
      add_work_intent_index(columns, name)
    end
  end

  def down
    INDEXES.each_key do |name|
      remove_index :work_intents, name: name if index_exists?(:work_intents, name: name)
    end
  end

  private

  def add_work_intent_index(columns, name)
    return if index_exists?(:work_intents, columns, name: name)

    add_index :work_intents, columns, name: name
  end
end
