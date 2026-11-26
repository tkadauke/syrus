module DesignDocs
  class Archive
    Result = Data.define(:design_doc, :previous_state, :new_state)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, user:, audit_reason: nil, pending_action: nil)
      @design_doc = design_doc
      @user = user
      @audit_reason = audit_reason
      @pending_action = pending_action
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).archive?

      previous_state = nil
      DesignDoc.transaction do
        design_doc.lock!
        previous_state = design_doc.state
        design_doc.update!(state: "archived") unless design_doc.state == "archived"
        audit!(previous_state: previous_state, new_state: design_doc.state)
      end

      Result.new(design_doc: design_doc.reload, previous_state: previous_state, new_state: design_doc.state)
    end

    private

    attr_reader :design_doc, :user, :audit_reason, :pending_action

    def audit!(previous_state:, new_state:)
      AdminAction.log!(
        user: user,
        action: "archive_design_doc",
        params: {
          design_doc_id: design_doc.id,
          doc_ref: design_doc.display_id,
          title: design_doc.title,
          previous_state: previous_state,
          new_state: new_state,
          reason: audit_reason.to_s,
          pending_action_id: pending_action&.id
        }.compact
      )
    end
  end
end
