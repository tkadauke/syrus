# Two booleans answered one question -- when do a pull request's CI checks hold
# a Job out of the landing queue? -- and they did not compose. One of their four
# combinations was incoherent (ignore every check, but specifically land on
# inherited failures), which is the shape RiskProfile's own header warns about:
# knobs that each make local sense and cannot be read together.
#
# One ordered value instead. "all" is the previous default, "own_only" is what
# land_on_inherited_check_failure = true meant, and "none" is new: checks stay
# advisory -- still cached, still feeding target health and main-branch repair
# -- but never decide whether a Job may land. Worth choosing when a
# repository's own graders already cover what its CI runs.
class ReplaceCheckFailureFlagsWithPrCheckGate < ActiveRecord::Migration[8.1]
  GATE = :pr_check_gate
  LEGACY = :land_on_inherited_check_failure

  def up
    unless column_exists?(:repositories, GATE)
      add_column :repositories, GATE, :string, default: "all", null: false
    end

    # Preserve every existing opt-out before the column it lived in goes away.
    if column_exists?(:repositories, LEGACY)
      execute(<<~SQL.squish)
        UPDATE repositories SET #{GATE} = 'own_only' WHERE #{LEGACY} = #{quoted_true}
      SQL
      remove_column :repositories, LEGACY
    end
  end

  def down
    unless column_exists?(:repositories, LEGACY)
      add_column :repositories, LEGACY, :boolean, default: false, null: false
    end

    if column_exists?(:repositories, GATE)
      # "none" has no boolean equivalent; it degrades to the closest one that
      # still lands on inherited failures rather than silently re-gating.
      execute(<<~SQL.squish)
        UPDATE repositories SET #{LEGACY} = #{quoted_true} WHERE #{GATE} IN ('own_only', 'none')
      SQL
      remove_column :repositories, GATE
    end
  end

  private

  def quoted_true
    connection.quote(connection.adapter_name.match?(/mysql/i) ? 1 : true)
  end
end
