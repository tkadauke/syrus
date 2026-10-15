module CredentialStore
  class CredentialAccessEvent < ApplicationRecord
    self.table_name = "credential_store_credential_access_events"

    SURFACES = %w[workflow chat admin api].freeze
    RESULTS = %w[allowed denied failed].freeze
    ACTIONS = %w[create update read lease use test rotate revoke].freeze
    TOOL_NAME_PATTERN = /\A[a-z][a-z0-9_.:-]*\z/

    belongs_to :credential, class_name: "CredentialStore::Credential", inverse_of: :access_events, optional: true
    belongs_to :lease_event, class_name: "CredentialStore::CredentialAccessEvent", optional: true
    has_one :completion_event, class_name: "CredentialStore::CredentialAccessEvent", foreign_key: :lease_event_id, inverse_of: :lease_event
    belongs_to :user, class_name: "::User", optional: true
    belongs_to :repository, class_name: "::Repository", optional: true
    belongs_to :job, class_name: "::Job", optional: true
    belongs_to :workflow, class_name: "::Workflow", optional: true
    belongs_to :run, class_name: "::Run", optional: true
    belongs_to :chat_session, class_name: "::ChatSession", optional: true

    validates :surface, presence: true, inclusion: { in: SURFACES }
    validates :action, presence: true, inclusion: { in: ACTIONS }
    validates :result, presence: true, inclusion: { in: RESULTS }
    validates :tool_name, format: { with: TOOL_NAME_PATTERN }, allow_nil: true
    validates :purpose, length: { maximum: 255 }, allow_nil: true
    validates :denial_reason, length: { maximum: 255 }, allow_nil: true
    validate :denial_reason_matches_result

    before_update { raise ActiveRecord::ReadOnlyRecord, "CredentialStore::CredentialAccessEvent is append-only" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "CredentialStore::CredentialAccessEvent is append-only" unless destroyed_by_association }

    def self.record!(credential:, surface:, action:, result:, user: nil, repository: nil, job: nil, workflow: nil, run: nil, chat_session: nil, lease_event: nil, tool_name: nil, purpose: nil, denial_reason: nil, metadata: {})
      metadata ||= {}
      create!(
        credential: credential,
        user: user,
        repository: repository,
        job: job,
        workflow: workflow,
        run: run,
        chat_session: chat_session,
        lease_event: lease_event,
        surface: surface,
        tool_name: tool_name,
        action: action,
        lease_id: metadata[:lease_id] || metadata["lease_id"],
        purpose: purpose,
        result: result,
        denial_reason: denial_reason,
        metadata: metadata
      )
    end

    private

    def denial_reason_matches_result
      errors.add(:denial_reason, "must be present when result is denied") if result == "denied" && denial_reason.blank?
      errors.add(:denial_reason, "must be blank unless result is denied") if result != "denied" && denial_reason.present?
    end
  end
end
