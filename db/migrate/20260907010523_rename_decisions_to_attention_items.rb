class RenameDecisionsToAttentionItems < ActiveRecord::Migration[8.1]
  # `Decision` collided in name with 6 pre-existing unrelated `Decision` value
  # classes (ProviderCircuitBreaker::Decision, WorkflowAdmissionBudget::Decision,
  # etc.) that are a different concept entirely (ephemeral selector-service
  # return values, not persisted records). No raw SQL/reporting code references
  # the `decisions` table name outside this model, so a plain rename is safe.
  OLD_QUEUE_INDEX = "index_decisions_on_queue_state_urgency".freeze
  NEW_QUEUE_INDEX = "index_attention_items_on_queue_state_urgency".freeze

  def up
    rename_table :decisions, :attention_items if table_exists?(:decisions) && !table_exists?(:attention_items)

    # `rename_table` only auto-renames indexes whose name matches the
    # Rails-generated default; this one was given an explicit shorter name.
    if index_exists?(:attention_items, [ :queue, :state, :urgency ], name: OLD_QUEUE_INDEX)
      rename_index :attention_items, OLD_QUEUE_INDEX, NEW_QUEUE_INDEX
    end
  end

  def down
    if index_exists?(:attention_items, [ :queue, :state, :urgency ], name: NEW_QUEUE_INDEX)
      rename_index :attention_items, NEW_QUEUE_INDEX, OLD_QUEUE_INDEX
    end

    rename_table :attention_items, :decisions if table_exists?(:attention_items) && !table_exists?(:decisions)
  end
end
