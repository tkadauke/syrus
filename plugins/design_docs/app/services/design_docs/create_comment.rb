module DesignDocs
  class CreateComment
    Result = Data.define(:design_doc, :anchor, :thread, :comment, :version)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, user:, attributes:, actor_kind: "user")
      @design_doc = design_doc
      @user = user
      @attributes = attributes
      @actor_kind = actor_kind.to_s.presence || "user"
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).suggest?

      DesignDoc.transaction do
        anchor_result = CreateAnchor.call(
          design_doc: design_doc,
          user: user,
          attributes: anchor_attributes,
          actor_kind: actor_kind
        )
        thread = design_doc.threads.create!(anchor: anchor_result.anchor, opened_by_user: user)
        comment = thread.comments.create!(
          author_kind: actor_kind,
          author_user: actor_kind == "user" ? user : nil,
          body: attributes[:body]
        )

        Result.new(design_doc: design_doc.reload, anchor: anchor_result.anchor, thread: thread, comment: comment, version: anchor_result.version)
      end
    end

    private

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def anchor_attributes
      attributes.slice(:start_offset, :end_offset, :selected_markdown, :selected_text, :anchor_kind)
        .merge(change_summary: "Add inline comment anchor")
    end
  end
end
