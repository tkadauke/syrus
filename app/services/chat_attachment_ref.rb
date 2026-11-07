class ChatAttachmentRef
  attr_reader :name, :mime_type, :size, :id

  def self.for(owner)
    content = owner.respond_to?(:content) ? owner.content : owner
    chat_session = owner.respond_to?(:chat_session) ? owner.chat_session : nil
    Array(content.is_a?(Hash) ? content["attachments"] : nil).filter_map do |attributes|
      new(attributes, chat_session: chat_session)
    rescue ActiveRecord::RecordNotFound, ArgumentError, KeyError
      nil
    end
  end

  def initialize(attributes, chat_session: nil)
    @attributes = attributes.to_h.stringify_keys
    @stored = stored_attachment(@attributes["id"], chat_session)
    @id = @stored&.id
    @name = @stored&.name || @attributes["name"].to_s
    @mime_type = @stored&.mime_type || @attributes["mime_type"].to_s
    @size = @stored&.byte_size || @attributes["size"]
  end

  def bytes = (@bytes ||= @stored ? @stored.file.download : Base64.strict_decode64(@attributes.fetch("data")))
  def stored? = @stored.present?

  def payload
    return @attributes.deep_dup unless stored?

    payload = { "id" => id, "name" => name, "mime_type" => mime_type,
                "data" => Base64.strict_encode64(bytes), "url" => file_url }.compact
    payload["size"] = size
    payload
  end

  def file_url
    "/api/v1/app/chats/#{@stored.chat_session_id}/attachments/#{id}/file" if stored?
  end

  private

  def stored_attachment(id, chat_session)
    return if id.blank?
    raise ActiveRecord::RecordNotFound unless chat_session
    chat_session.chat_file_attachments.includes(file_attachment: :blob).find(id)
  end
end
