require "fileutils"

module Prompts
  module Truncate
    MARKER_TEMPLATE = "\n...[%<label>s truncated, %<bytes>d more bytes%<location>s]".freeze
    COLLECTION_MARKER_TEMPLATE = "...[%<count>d %<noun>s omitted due to limits%<location>s]".freeze

    class Spill
      DEFAULT_MAX_BYTES = 1.megabyte

      def initialize(workspace_path:, key:, max_bytes: DEFAULT_MAX_BYTES)
        @workspace_path = Pathname(workspace_path)
        @directory = @workspace_path.join(".syrus", "prompt-context", key.to_s)
        @max_bytes = max_bytes
        @written_bytes = 0
        @filenames = Hash.new(0)
      end

      def write(label, content, extension: ".txt")
        content = content.to_s
        return if content.bytesize > @max_bytes - @written_bytes

        basename = label.to_s.parameterize.presence || "content"
        @filenames[basename] += 1
        suffix = @filenames[basename] == 1 ? "" : "-#{@filenames[basename]}"
        path = @directory.join("#{basename}#{suffix}#{extension}")
        FileUtils.mkdir_p(@directory)
        File.binwrite(path, content)
        @written_bytes += content.bytesize
        path.relative_path_from(@workspace_path).to_s
      end
    end

    module_function

    def text(value, max_bytes:, label: "content", spill: nil)
      value = value.to_s
      return value if value.bytesize <= max_bytes

      retained = value.safe_byteslice(0, max_bytes)
      path = spill&.write(label, value)
      marker = format(MARKER_TEMPLATE, label: label, bytes: value.bytesize - retained.bytesize,
        location: path ? "; full text: #{path}" : "")
      "#{retained}#{marker}"
    end

    def collection(items, max_items:, max_bytes:, priority: ->(_item) { false }, spill: nil, label: "comments", &renderer)
      items = Array(items)
      priority_items = items.select(&priority)
      background = items.reject(&priority).last(max_items)
      selected = (priority_items + background).uniq.sort_by { |item| items.index(item) }
      rendered_items = selected.map { |item| [ item, renderer.call(item) ] }
      omitted = items - selected

      while joined_bytesize(rendered_items) > max_bytes
        removable_index = if rendered_items.size > 1
          rendered_items.index { |item, _text| !priority.call(item) }
        end
        removable_index ||= 0 if rendered_items.size > 1
        break unless removable_index

        omitted << rendered_items.delete_at(removable_index).first
      end

      if joined_bytesize(rendered_items) > max_bytes
        per_item_bytes = [ max_bytes / rendered_items.size, 1 ].max
        rendered_items.map! do |item, rendered_text|
          [ item, text(rendered_text, max_bytes: per_item_bytes, label: "comment thread entry", spill: spill) ]
        end
      end

      rendered = rendered_items.map(&:last).join("\n\n")
      return rendered if omitted.empty?

      omitted.sort_by! { |item| items.index(item) }
      path = spill&.write("#{label}-omitted", omitted.map { |item| renderer.call(item) }.join("\n\n"), extension: ".md")
      noun = omitted.size == 1 ? "comment" : "comments"
      marker = format(COLLECTION_MARKER_TEMPLATE, count: omitted.size, noun: noun,
        location: path ? "; full text: #{path}" : "")
      "#{rendered}\n\n#{marker}"
    end

    def joined_bytesize(rendered_items)
      rendered_items.sum { |_item, rendered_text| rendered_text.bytesize } + ([ rendered_items.size - 1, 0 ].max * 2)
    end
  end
end
