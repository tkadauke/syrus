module Syrus
  module Plugin
    module SlugType
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def prefix
          raise NotImplementedError, "#{name} must implement .prefix"
        end

        def display_label
          raise NotImplementedError, "#{name} must implement .display_label"
        end

        def type_key
          prefix.downcase
        end

        def id_pattern
          /\d+/
        end

        def copyable?
          true
        end

        def preview_available?
          false
        end

        def linkifies_generated_text?
          true
        end

        def mobile_interaction_hints
          {
            "tap" => "open",
            "long_press" => copyable? ? "copy" : nil
          }.compact
        end

        def slug_pattern
          /\A#{Regexp.escape(prefix)}-(#{id_pattern.source})\z/i
        end

        def claims?(slug)
          slug.to_s.match?(/\A#{Regexp.escape(prefix)}-/i)
        end

        def parse_id(slug)
          match = slug.to_s.match(slug_pattern)
          return nil unless match

          Integer(match[1], exception: false)
        end

        def canonical_slug(id)
          "#{prefix}-#{id}"
        end

        def resolve(slug, user:)
          id = parse_id(slug)
          return SlugRefs::Resolution.malformed(provider: self) unless id

          record = record_for(id, user: user)
          return SlugRefs::Resolution.inaccessible(provider: self, id: id) unless record

          SlugRefs::Resolution.accessible(provider: self, id: id, record: record)
        end

        def record_for(_id, user:)
          raise NotImplementedError, "#{name} must implement .record_for"
        end

        def web_path(_record)
          raise NotImplementedError, "#{name} must implement .web_path"
        end

        def api_preview_path(_record)
          nil
        end
      end
    end
  end
end
