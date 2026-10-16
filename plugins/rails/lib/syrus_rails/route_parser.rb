require "active_support/inflector"

module SyrusRails
  # Best-effort parser for Rails config/routes.rb files.
  # Handles: resources, resource, get/post/patch/put/delete/match,
  # namespace, scope, and root. Deep nesting (>2 levels) is approximate.
  class RouteParser
    RESOURCE_ACTIONS = {
      "index"   => { method: "GET",    suffix: "" },
      "new"     => { method: "GET",    suffix: "/new" },
      "create"  => { method: "POST",   suffix: "" },
      "show"    => { method: "GET",    suffix: "/:id" },
      "edit"    => { method: "GET",    suffix: "/:id/edit" },
      "update"  => { method: "PATCH",  suffix: "/:id" },
      "destroy" => { method: "DELETE", suffix: "/:id" }
    }.freeze

    SINGULAR_ACTIONS = RESOURCE_ACTIONS.reject { |a, _| a == "index" }.freeze

    def self.parse(path)
      new(File.read(path)).parse
    end

    def initialize(content)
      @content = content
      @routes  = []
    end

    def parse
      context_stack = []  # stack of { prefix:, module: } hashes
      @content.each_line do |raw|
        line = strip_comment(raw).strip
        next if line.empty?

        if closes_block?(line) && context_stack.any?
          context_stack.pop
          next
        end

        prefix = current_prefix(context_stack)
        mod    = current_module(context_stack)
        stack_size = context_stack.size

        parse_line(line, prefix, mod, context_stack)
        push_scope(context_stack, **current_context(context_stack)) if opens_block?(line) && context_stack.size == stack_size
      end

      { routes: @routes }
    end

    private

    def strip_comment(line)
      quote = nil
      escaped = false

      line.each_char.with_index do |char, index|
        if escaped
          escaped = false
        elsif quote && char == "\\"
          escaped = true
        elsif quote
          quote = nil if char == quote
        elsif char == '"' || char == "'"
          quote = char
        elsif char == "#"
          return line[0...index]
        end
      end

      line
    end

    def parse_line(line, prefix, mod, stack)
      if (m = line.match(/\bresources\s+:(\w+)(.*)/))
        emit_resources(m[1], m[2], prefix, mod, plural: true)
        if opens_block?(line)
          push_scope(stack, prefix: "#{prefix}/#{m[1]}/:#{m[1].singularize}_id",
            collection_prefix: "#{prefix}/#{m[1]}", member_prefix: "#{prefix}/#{m[1]}/:id",
            mod: mod, controller: m[1])
        end

      elsif (m = line.match(/\bresource\s+:(\w+)(.*)/))
        emit_resources(m[1], m[2], prefix, mod, plural: false)
        push_scope(stack, prefix: "#{prefix}/#{m[1]}", collection_prefix: "#{prefix}/#{m[1]}",
          member_prefix: "#{prefix}/#{m[1]}", mod: mod, controller: m[1]) if opens_block?(line)

      elsif (m = line.match(/\bnamespace\s+:(\w+)(.*)/))
        push_scope(stack, **current_context(stack).merge(prefix: "#{prefix}/#{m[1]}", mod: "#{mod}#{m[1]}/")) if opens_block?(line)

      elsif (m = line.match(/\bscope\s+["']([^"']+)["'](.*)/))
        push_scope(stack, **current_context(stack).merge(prefix: "#{prefix}#{m[1]}", mod: mod)) if opens_block?(line)

      elsif (m = line.match(/\bscope\s+module:\s*:(\w+)(.*)/))
        push_scope(stack, **current_context(stack).merge(prefix: prefix, mod: "#{mod}#{m[1]}/")) if opens_block?(line)

      elsif line.match?(/\bcollection\s+do\b/)
        push_scope(stack, **current_context(stack).merge(prefix: current_context(stack)[:collection_prefix] || prefix))

      elsif line.match?(/\bmember\s+do\b/)
        push_scope(stack, **current_context(stack).merge(prefix: current_context(stack)[:member_prefix] || prefix))

      elsif (m = line.match(/\broot\s+(?:to:\s*)?["']([^"']+)["']/))
        controller, action = m[1].split("#")
        @routes << route("GET", "#{prefix}/", "#{mod}#{controller}", action || "index", "root")

      elsif (m = line.match(/\b(get|post|patch|put|delete|match)\s+(?:["']([^"']+)["']|:(\w+))(.*)/))
        path = m[2] || m[3]
        emit_verb_route(m[1].upcase, "#{prefix}/#{path}".gsub(%r{/+}, "/"), m[4], mod,
          default_controller: current_context(stack)[:controller], default_action: path)

      end
    end

    def emit_resources(name, rest, prefix, mod, plural:)
      actions = if (only_m = rest.match(/only:\s*(%[iw]\[[^\]]*\]|\[[^\]]*\]|:\w+)/))
        extract_actions(only_m[1])
      elsif (except_m = rest.match(/except:\s*(%[iw]\[[^\]]*\]|\[[^\]]*\]|:\w+)/))
        base = plural ? RESOURCE_ACTIONS.keys : SINGULAR_ACTIONS.keys
        base - extract_actions(except_m[1])
      else
        plural ? RESOURCE_ACTIONS.keys : SINGULAR_ACTIONS.keys
      end

      action_map = plural ? RESOURCE_ACTIONS : SINGULAR_ACTIONS
      base_path  = "#{prefix}/#{name}"
      controller = name

      actions.each do |action|
        next unless action_map.key?(action)

        meta        = action_map[action]
        path        = "#{base_path}#{meta[:suffix]}"
        route_name  = route_name_for(action, name, plural: plural)

        @routes << route(meta[:method], path, "#{mod}#{controller}", action, route_name)
      end
    end

    def extract_actions(value)
      value.scan(/\w+/).reject { |word| %w[i w].include?(word) }
    end

    def emit_verb_route(method, raw_path, rest, mod, default_controller:, default_action:)
      path = raw_path.gsub(%r{/+}, "/")
      if (to_m = rest.match(/to:\s*["']([^"']+)["']/))
        controller, action = to_m[1].split("#")
        name_m = rest.match(/as:\s*:(\w+)/)
        @routes << route(method, path, "#{mod}#{controller}", action || "index", name_m&.send(:[], 1))
      elsif default_controller
        @routes << route(method, path, "#{mod}#{default_controller}", default_action, nil)
      end
    end

    def route(method, path, controller, action, name)
      { method: method, path: path, controller_action: "#{controller}##{action}", name: name }.compact
    end

    def route_name_for(action, resource, plural:)
      singular = plural ? resource.singularize : resource
      case action
      when "index"   then resource
      when "new"     then "new_#{singular}"
      when "create"  then resource
      when "show"    then singular
      when "edit"    then "edit_#{singular}"
      when "update"  then singular
      when "destroy" then singular
      end
    end

    def opens_block?(line)
      line.end_with?("do") || line.match?(/\bdo\s*(\|[^|]*\|)?\s*$/)
    end

    def closes_block?(line)
      line == "end" || line.start_with?("end ")
    end

    def current_prefix(stack)
      stack.last&.dig(:prefix) || ""
    end

    def current_module(stack)
      stack.last&.dig(:mod) || ""
    end

    def current_context(stack)
      stack.last || { prefix: "", collection_prefix: "", member_prefix: "", mod: "", controller: nil }
    end

    def push_scope(stack, prefix:, mod:, collection_prefix: nil, member_prefix: nil, controller: nil)
      stack.push({ prefix: prefix, collection_prefix: collection_prefix, member_prefix: member_prefix,
        mod: mod, controller: controller })
    end
  end
end
