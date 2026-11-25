class AddAgentQuestionPolicySettings < ActiveRecord::Migration[8.1]
  TABLES = %i[jobs repositories users].freeze

  def up
    TABLES.each do |table|
      add_column table, :question_eagerness, :string unless column_exists?(table, :question_eagerness)
      add_column table, :question_answer_timeout_seconds, :integer unless column_exists?(table, :question_answer_timeout_seconds)
    end
    add_column :jobs, :question_eagerness_reason, :text unless column_exists?(:jobs, :question_eagerness_reason)
  end

  def down
    remove_column :jobs, :question_eagerness_reason if column_exists?(:jobs, :question_eagerness_reason)
    TABLES.each do |table|
      remove_column table, :question_answer_timeout_seconds if column_exists?(table, :question_answer_timeout_seconds)
      remove_column table, :question_eagerness if column_exists?(table, :question_eagerness)
    end
  end
end
