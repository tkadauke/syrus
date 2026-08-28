require_relative "../seeds/themes"

# Production's `themes` table predates EPIC-273's follow-up expansion job:
# `db:prepare` only runs `db:seed` when the database is created fresh, so an
# existing production database never got the `Seeds::Themes.seed!` upsert or
# the `color_theme_id` backfill that db/seeds.rb performs. Running the same
# idempotent seed module from a real migration means both run through the
# normal db:migrate/db:prepare path regardless of whether the database is
# fresh or pre-existing.
class SeedBuiltInThemes < ActiveRecord::Migration[8.1]
  def up
    Seeds::Themes.seed!

    if (terracotta = Theme.terracotta)
      User.where(color_theme_id: nil).update_all(color_theme_id: terracotta.id)
    end
  end

  def down
    # Intentionally irreversible: this seeds/backfills data, it doesn't
    # change schema. Rolling back would mean guessing which Theme rows and
    # User#color_theme_id assignments predate this migration versus came
    # from db/seeds.rb running normally elsewhere.
  end
end
