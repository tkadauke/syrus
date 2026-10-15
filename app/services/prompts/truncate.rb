module Prompts
  module Truncate
    MARKER_TEMPLATE = "\n...[%<label>s truncated, %<bytes>d more bytes]".freeze

    module_function

    def text(value, max_bytes:, label: "content")
      value = value.to_s
      return value if value.bytesize <= max_bytes

      marker = format(MARKER_TEMPLATE, label: label, bytes: value.bytesize - max_bytes)
      "#{value.safe_byteslice(0, max_bytes)}#{marker}"
    end

    # Prioritizes every important item (for example, [NEW] review comments),
    # then fills the item allowance with the newest background items. The byte
    # cap remains authoritative for an adversarial thread made entirely of
    # priority items, with any final omissions called out explicitly.
    def collection(items, max_items:, max_bytes:, priority: ->(_item) { false }, &renderer)
      items = Array(items)
      priority_items = items.select(&priority)
      background = items.reject(&priority).last(max_items)
      selected = (priority_items + background).uniq.sort_by { |item| items.index(item) }
      rendered_items = selected.map { |item| [ item, renderer.call(item) ] }
      omitted_items = items.size - selected.size

      while joined_bytesize(rendered_items) > max_bytes
        background_count = rendered_items.count { |item, _text| !priority.call(item) }
        removable_index = if background_count > 1
          rendered_items.index { |item, _text| !priority.call(item) }
        elsif rendered_items.size > 1
          0
        end
        break unless removable_index

        rendered_items.delete_at(removable_index)
        omitted_items += 1
      end

      if joined_bytesize(rendered_items) > max_bytes
        per_item_bytes = [ max_bytes / rendered_items.size, 1 ].max
        rendered_items.map! do |item, text|
          [ item, truncate_collection_item(text, per_item_bytes) ]
        end
      end

      rendered = rendered_items.map(&:last).join("\n\n")
      return rendered if omitted_items.zero?

      "#{rendered}\n\n...[#{omitted_items} comments omitted due to limits]"
    end

    def joined_bytesize(rendered_items)
      rendered_items.sum { |_item, text| text.bytesize } + ([ rendered_items.size - 1, 0 ].max * 2)
    end

    def truncate_collection_item(text, max_bytes)
      self.text(text, max_bytes: max_bytes, label: "comment thread entry")
    end
  end
end
