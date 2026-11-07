class ChatAttachmentRef
  attr_reader :name, :mime_type, :size, :id

  def self.preload(owners)
    owners = Array(owners)
    references = owners.to_h do |owner|
      ids = attachment_attributes(owner).filter_map { |entry| entry.to_h.stringify_keys["id"].presence }.map(&:to_i)
      [ owner, ids ]
    end
    ids = references.values.flatten.uniq
    stored_by_key = if ids.empty?
      {}
    else
      ChatFileAttachment.includes(file_attachment: :blob)
        .where(id: ids, chat_session_id: owners.filter_map(&:chat_session_id).uniq)
        .index_by { |attachment| [ attachment.chat_session_id, attachment.id ] }
    end

    owners.each do |owner|
      owner.instance_variable_set(:@chat_attachment_refs_by_id, references.fetch(owner).to_h do |id|
        [ id, stored_by_key[[ owner.chat_session_id, id ]] ]
      end)
    end
    owners
  end

  def self.for(owner)
    attributes_list = attachment_attributes(owner)
    preloaded_by_id = owner.instance_variable_get(:@chat_attachment_refs_by_id) if owner.respond_to?(:chat_session)
    chat_session = preloaded_by_id ? true : owner.try(:chat_session)
    attributes_list.filter_map.with_index do |attributes, index|
      new(attributes, owner: owner, index: index, chat_session: chat_session, preloaded_by_id: preloaded_by_id)
    rescue ActiveRecord::RecordNotFound, ArgumentError, KeyError
      nil
    end
  end

  def self.attachment_attributes(owner)
    content = owner.respond_to?(:content) ? owner.content : owner
    content = JSON.parse(content) if content.is_a?(String)
    Array(content.is_a?(Hash) ? content["attachments"] : nil)
  rescue JSON::ParserError
    []
  end
  private_class_method :attachment_attributes

  def initialize(attributes, owner: nil, index: nil, chat_session: nil, preloaded_by_id: nil)
    @attributes = attributes.to_h.stringify_keys
    @stored = stored_attachment(@attributes["id"], chat_session, preloaded_by_id)
    @id = @stored&.id
    @name = @stored&.name || @attributes["name"].to_s
    @mime_type = @stored&.mime_type || @attributes["mime_type"].to_s
    @size = @stored&.byte_size || @attributes["size"] || legacy_size
    @owner = owner
    @index = index
  end

  def bytes = (@bytes ||= @stored ? @stored.file.download : Base64.strict_decode64(@attributes["data"].to_s))
  def stored? = @stored.present?
  def bytes_present? = stored? || @attributes["data"].present?

  def payload
    payload = { "id" => id, "name" => name, "mime_type" => mime_type, "url" => file_url }.compact
    payload["size"] = size
    payload
  end

  def file_url
    return "/api/v1/app/chats/#{@stored.chat_session_id}/attachments/#{id}/file" if stored?
    return unless @owner.respond_to?(:id) && @owner.id && !@index.nil?

    "/api/v1/app/chats/#{@owner.chat_session_id}/messages/#{@owner.id}/attachments/#{@index}"
  end

  private

  def legacy_size
    Base64.strict_decode64(@attributes["data"].to_s).bytesize if @attributes["data"].present?
  rescue ArgumentError
    nil
  end

  def stored_attachment(id, chat_session, preloaded_by_id)
    return if id.blank?
    raise ActiveRecord::RecordNotFound unless chat_session
    if preloaded_by_id
      attachment = preloaded_by_id.fetch(id.to_i)
      raise ActiveRecord::RecordNotFound unless attachment
      return attachment
    end
    chat_session.chat_file_attachments.includes(file_attachment: :blob).find(id)
  end
end
