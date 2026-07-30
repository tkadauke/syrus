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
        line = raw.strip
        next if line.start_with?("#") || line.empty?

        if closes_block?(line) && context_stack.any?
          context_stack.pop
          next
        end

        prefix = current_prefix(context_stack)
        mod    = current_module(context_stack)

        parse_line(line, prefix, mod, context_stack)
      end

      { routes: @routes }
    end

    private

    def parse_line(line, prefix, mod, stack)
      if (m = line.match(/\bresources\s+:(\w+)(.*)/))
        emit_resources(m[1], m[2], prefix, mod, plural: true)
        push_scope(stack, prefix: "#{prefix}/#{m[1]}/:#{m[1].chomp('s')}_id", mod: mod) if opens_block?(line)

      elsif (m = line.match(/\bresource\s+:(\w+)(.*)/))
        emit_resources(m[1], m[2], prefix, mod, plural: false)
        push_scope(stack, prefix: "#{prefix}/#{m[1]}", mod: mod) if opens_block?(line)

      elsif (m = line.match(/\bnamespace\s+:(\w+)(.*)/))
        push_scope(stack, prefix: "#{prefix}/#{m[1]}", mod: "#{mod}#{m[1]}/") if opens_block?(line)

      elsif (m = line.match(/\bscope\s+["']([^"']+)["'](.*)/))
        push_scope(stack, prefix: "#{prefix}#{m[1]}", mod: mod) if opens_block?(line)

      elsif (m = line.match(/\bscope\s+module:\s*:(\w+)(.*)/))
        push_scope(stack, prefix: prefix, mod: "#{mod}#{m[1]}/") if opens_block?(line)

      elsif (m = line.match(/\broot\s+(?:to:\s*)?["']([^"']+)["']/))
        controller, action = m[1].split("#")
        @routes << route("GET", "#{prefix}/", "#{mod}#{controller}", action || "index", "root")

      elsif (m = line.match(/\b(get|post|patch|put|delete|match)\s+["']([^"']+)["'](.*)/))
        emit_verb_route(m[1].upcase, "#{prefix}/#{m[2]}".gsub(%r{/+}, "/"), m[3], mod)

      end
    end

    def emit_resources(name, rest, prefix, mod, plural:)
      actions = if (only_m = rest.match(/only:\s*%?[wi]\[([^\]]+)\]/))
        only_m[1].split
      elsif (except_m = rest.match(/except:\s*%?[wi]\[([^\]]+)\]/))
        base = plural ? RESOURCE_ACTIONS.keys : SINGULAR_ACTIONS.keys
        base - except_m[1].split
      elsif (only_m = rest.match(/only:\s*%i\[\s*([^\]]+)\s*\]/))
        only_m[1].split
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

    def emit_verb_route(method, raw_path, rest, mod)
      path = raw_path.gsub(%r{/+}, "/")
      if (to_m = rest.match(/to:\s*["']([^"']+)["']/))
        controller, action = to_m[1].split("#")
        name_m = rest.match(/as:\s*:(\w+)/)
        @routes << route(method, path, "#{mod}#{controller}", action || "index", name_m&.send(:[], 1))
      end
    end

    def route(method, path, controller, action, name)
      { method: method, path: path, controller_action: "#{controller}##{action}", name: name }.compact
    end

    def route_name_for(action, resource, plural:)
      singular = plural ? resource.chomp("s") : resource
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

    def push_scope(stack, prefix:, mod:)
      stack.push({ prefix: prefix, mod: mod })
    end
  end
end
