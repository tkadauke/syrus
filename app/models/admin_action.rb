class AdminAction < ApplicationRecord
  belongs_to :user
  serialize :params, coder: JSON

  validates :action, presence: true
  validates :performed_at, presence: true

  before_update { raise ActiveRecord::ReadOnlyRecord, "AdminAction is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "AdminAction is append-only" unless destroyed_by_association }

  scope :recent, -> { order(performed_at: :desc).limit(50) }

  # Convenience: log an action against the current user. Caller
  # passes a symbol/string `action` and an optional params Hash
  # (gets JSON-encoded). Returns the persisted record so callers
  # can chain or assert on it in tests.
  def self.log!(user:, action:, params: {})
    create!(user: user, action: action.to_s, params: bounded_params(params), performed_at: Time.current)
  end

  # The params column is MEDIUMTEXT on MySQL. An audit row is written after
  # the action it records has already run, so it must not fail on size: the
  # repair snapshots, which are what grows, are replaced by a note of their
  # size rather than lost along with the whole row.
  PARAMS_BYTE_LIMIT = 15.megabytes
  OVERSIZED_KEYS = %w[before_snapshot after_snapshot].freeze

  def self.bounded_params(params)
    return params unless params.is_a?(Hash) && params.to_json.bytesize > PARAMS_BYTE_LIMIT

    params.to_h { |key, value|
      next [ key, value ] unless OVERSIZED_KEYS.include?(key.to_s) && !value.nil?

      [ key, { "omitted" => "snapshot exceeded the audit size limit", "bytes" => value.to_json.bytesize } ]
    }
  end
end
