require "cgi"

module SyrusMail
  class ResultShaper
    MAX_INLINE_BODY_BYTES = 16.kilobytes

    def self.call(result, context:)
      new(result.deep_stringify_keys, context:).call
    end

    def initialize(result, context:)
      @result = result
      @context = context
    end

    def call
      shape_message!(@result) if @result.key?("body")
      Array(@result["messages"]).each { |message| shape_message!(message) }
      @result.merge("trust" => "external_untrusted", "provenance" => "external_untrusted")
    end

    private

    def shape_message!(message)
      message["body"] = strip_markup(message["body"].to_s)
      if message["body"].bytesize > MAX_INLINE_BODY_BYTES
        message["body_file"] = write_file("body.txt", message.delete("body"))
      end
      attachments = Array(message.delete("attachments"))
      message["attachment_files"] = attachments.map.with_index do |attachment, index|
        write_file("attachment-#{index + 1}-#{safe_name(attachment["filename"])}", attachment["content"].to_s)
      end if attachments.any?
      message
    end

    def strip_markup(value)
      CGI.unescapeHTML(value.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip)
    end

    def write_file(name, content)
      directory = workspace_root.join("external-content", SecureRandom.hex(8))
      FileUtils.mkdir_p(directory)
      path = directory.join(name)
      File.binwrite(path, content)
      path.relative_path_from(workspace_root).to_s
    end

    def safe_name(name) = File.basename(name.to_s.presence || "attachment.bin").gsub(/[^a-zA-Z0-9._-]/, "_")

    def workspace_root
      @workspace_root ||= if @context.chat_session
        ChatWorkspace.path_for(@context.chat_session)
      elsif @context.workflow
        WorkflowWorkspace.path_for(@context.workflow)
      else
        Pathname.new(Dir.tmpdir).join("syrus-external-content")
      end.tap { |path| FileUtils.mkdir_p(path) }
    end
  end
end
