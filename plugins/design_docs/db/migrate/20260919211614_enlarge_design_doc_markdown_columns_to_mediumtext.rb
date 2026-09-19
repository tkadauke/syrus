class EnlargeDesignDocMarkdownColumnsToMediumtext < ActiveRecord::Migration[8.1]
  # MySQL's default TEXT column caps at 65 KB, which is too small for
  # design docs: a live long-form bug sweep report overflowed
  # design_docs.markdown before SQLite-backed dev/test could catch it.
  #
  # Promote document-sized payloads to MEDIUMTEXT (16 MB), matching the
  # existing large text migrations:
  #   - design_docs.markdown / design_doc_versions.markdown store the
  #     canonical working body and append-only history.
  #   - design_doc_anchors.selected_markdown / selected_text can hold a
  #     full-document selection.
  #   - design_doc_suggestions original/suggested/proposed markdown can
  #     hold full-document agent or operator suggestions.
  #
  # Leave design_doc_comments.body as plain TEXT: comments are discussion
  # snippets, not the document body or replacement payload.
  PROMOTIONS = [
    %i[ design_docs markdown ],
    %i[ design_doc_versions markdown ],
    %i[ design_doc_anchors selected_markdown ],
    %i[ design_doc_anchors selected_text ],
    %i[ design_doc_suggestions original_markdown ],
    %i[ design_doc_suggestions suggested_markdown ],
    %i[ design_doc_suggestions proposed_markdown ]
  ].freeze

  def up
    return unless mysql?

    PROMOTIONS.each do |table, column|
      next unless column_exists?(table, column)

      change_column table, column, :text, limit: 16.megabytes
    end
  end

  def down
    return unless mysql?

    PROMOTIONS.each do |table, column|
      next unless column_exists?(table, column)

      change_column table, column, :text
    end
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
