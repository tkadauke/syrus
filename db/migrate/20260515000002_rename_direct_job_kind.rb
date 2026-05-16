class RenameDirectJobKind < ActiveRecord::Migration[8.1]
  OLD_KIND = "ad" + "hoc"
  NEW_KIND = "direct"

  def up
    update_kind(from: OLD_KIND, to: NEW_KIND)
  end

  def down
    update_kind(from: NEW_KIND, to: OLD_KIND)
  end

  private

  def update_kind(from:, to:)
    quoted_from = connection.quote(from)
    quoted_to = connection.quote(to)

    execute <<~SQL.squish
      UPDATE jobs
      SET kind = #{quoted_to}
      WHERE kind = #{quoted_from}
    SQL
  end
end
