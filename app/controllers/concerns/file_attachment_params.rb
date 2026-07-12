module FileAttachmentParams
  extend ActiveSupport::Concern

  included do
    class_attribute :attachment_param_key
  end

  private

  def uploaded_files
    Array(params.dig(attachment_param_key, :files)).compact_blank
  end

  def google_doc_url
    params.dig(attachment_param_key, :google_doc_url).to_s.strip
  end
end
