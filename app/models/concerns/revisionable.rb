# Stamps a monotonically increasing `entity_revision` on every save,
# independent of Rails optimistic locking (no StaleObjectError semantics --
# this column exists purely so app events and REST snapshots can be
# compared for recency without relying on `updated_at`, whose timestamp
# precision and independently-stamped `occurred_at` broadcast time don't
# guarantee ordering). Named to match the frontend entity store's existing
# `fields.entity_revision` fallback (app/frontend/lib/entityStore.ts).
module Revisionable
  extend ActiveSupport::Concern

  included do
    before_save :bump_entity_revision
  end

  private

  def bump_entity_revision
    self.entity_revision = (entity_revision || 0) + 1
  end
end
