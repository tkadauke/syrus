require "cgi"
module PersonalCalendar
  class ResultShaper
    MAX_INLINE_BODY_BYTES = 16.kilobytes
    def self.call(result, context:) = new(result.deep_stringify_keys, context:).call
    def initialize(result, context:) = (@result, @context = result, context)
    def call
      Array(@result["events"]).each { |event| shape!(event) }
      shape!(@result["event"]) if @result["event"]
      @result.merge("trust" => "external_untrusted", "provenance" => "external_untrusted")
    end
    private
    def shape!(event)
      %w[description notes].each do |field|
        next unless event[field]
        value = CGI.unescapeHTML(event[field].to_s.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip)
        if value.bytesize > MAX_INLINE_BODY_BYTES
          event["#{field}_file"] = write_file("#{field}.txt", value)
          event.delete(field)
        else
          event[field] = value
        end
      end
      attachments = Array(event.delete("attachments"))
      event["attachment_files"] = attachments.map.with_index { |item, index| write_file("attachment-#{index + 1}-#{safe_name(item["filename"])}", item["content"].to_s) } if attachments.any?
    end
    def write_file(name, content)
      directory = workspace_root.join("external-content", SecureRandom.hex(8))
      FileUtils.mkdir_p(directory)
      File.binwrite(directory.join(name), content)
      directory.join(name).relative_path_from(workspace_root).to_s
    end
    def safe_name(name) = File.basename(name.to_s.presence || "attachment.bin").gsub(/[^a-zA-Z0-9._-]/, "_")
    def workspace_root
      @workspace_root ||= if @context.chat_session
        Syrus::Host::ChatWorkspace.path_for(@context.chat_session)
      elsif @context.workflow
        Syrus::Host::WorkflowWorkspace.path_for(@context.workflow)
      else
        Pathname.new(Dir.tmpdir).join("syrus-external-content")
      end.tap { |path| FileUtils.mkdir_p(path) }
    end
  end
end
