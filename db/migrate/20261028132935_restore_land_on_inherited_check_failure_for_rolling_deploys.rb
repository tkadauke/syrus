class RestoreLandOnInheritedCheckFailureForRollingDeploys < ActiveRecord::Migration[8.1]
  LEGACY = :land_on_inherited_check_failure

  def up
    unless column_exists?(:repositories, LEGACY)
      add_column :repositories, LEGACY, :boolean, default: false, null: false
    end

    execute(<<~SQL.squish)
      UPDATE repositories
      SET #{LEGACY} = #{quoted_true}
      WHERE pr_check_gate IN ('own_only', 'none')
    SQL
  end

  def down
    remove_column :repositories, LEGACY if column_exists?(:repositories, LEGACY)
  end

  private

  def quoted_true
    connection.quote(connection.adapter_name.match?(/mysql/i) ? 1 : true)
  end
end
