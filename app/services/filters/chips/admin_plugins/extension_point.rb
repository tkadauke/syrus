module Filters
  module Chips
    module AdminPlugins
      class ExtensionPoint < Base
        filter_name "extension_point"
        label "Extension point"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of, :is_set, :is_unset
        values(*Syrus::PluginRegistry::EXTENSION_POINTS.map { |point| point.to_s })

        def apply
          case op
          when :is then contains_any([ value ])
          when :is_not then contains_none([ value ])
          when :is_one_of then contains_any(value)
          when :is_none_of then contains_none(value)
          when :is_set then scope.where.not(extension_points: [ nil, "" ])
          when :is_unset then scope.where(extension_points: [ nil, "" ])
          else unsupported_op!
          end
        end

        private

        def contains_any(points)
          tokens = normalized_tokens(points)
          return scope.none if tokens.empty?

          fragments = tokens.map { "extension_points LIKE ? ESCAPE #{like_escape_sql}" }
          scope.where(fragments.join(" OR "), *tokens.map { |token| "%\n#{escape_like(token)}\n%" })
        end

        def contains_none(points)
          tokens = normalized_tokens(points)
          return scope if tokens.empty?

          fragments = tokens.map { "extension_points NOT LIKE ? ESCAPE #{like_escape_sql}" }
          scope.where(extension_points: [ nil, "" ]).or(scope.where(fragments.join(" AND "), *tokens.map { |token| "%\n#{escape_like(token)}\n%" }))
        end

        def normalized_tokens(points)
          Array(points).map(&:to_s).select { |point| Syrus::PluginRegistry::EXTENSION_POINTS.include?(point.to_sym) }.uniq
        end
      end
    end
  end
end
