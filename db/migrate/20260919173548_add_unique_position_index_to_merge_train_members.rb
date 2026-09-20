class AddUniquePositionIndexToMergeTrainMembers < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_merge_train_members_on_merge_train_id_and_position"

  def up
    if index_exists?(:merge_train_members, [ :merge_train_id, :position ], name: INDEX_NAME) &&
        !index_exists?(:merge_train_members, [ :merge_train_id, :position ], name: INDEX_NAME, unique: true)
      remove_index :merge_train_members, name: INDEX_NAME
    end

    unless index_exists?(:merge_train_members, [ :merge_train_id, :position ], name: INDEX_NAME)
      add_index :merge_train_members,
        [ :merge_train_id, :position ],
        unique: true,
        name: INDEX_NAME
    end
  end

  def down
    remove_index :merge_train_members, name: INDEX_NAME if index_exists?(:merge_train_members, name: INDEX_NAME)

    unless index_exists?(:merge_train_members, [ :merge_train_id, :position ], name: INDEX_NAME)
      add_index :merge_train_members,
        [ :merge_train_id, :position ],
        name: INDEX_NAME
    end
  end
end
