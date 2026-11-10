# One large value lifted out of steps.details. See Step#details for how the
# side table and the inline column are merged.
class StepDetailValue < ApplicationRecord
  # The only detail keys stored here. An explicit allowlist rather than a size
  # threshold: whether a key is inline or external must not depend on runtime
  # data, or every reader would have to check both places forever. Adding a key
  # is one edit here plus a backfill.
  EXTERNALIZED_KEYS = %w[ output ].freeze

  belongs_to :step, inverse_of: :step_detail_values

  validates :key, presence: true, uniqueness: { scope: :step_id }

  serialize :value, coder: JSON
end
