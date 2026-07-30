module SyrusRails
  # Parser for Rails migration files. Computes before/after column state
  # by reading the current schema and reversing the migration's changes.
  #
  # Supports: add_column, remove_column, rename_column, change_column,
  #           create_table, drop_table, add_index, remove_index.
  class MigrationParser
    Change = Struct.new(:kind, :table, :column, :type, :options, keyword_init: true)

    def self.parse(migration_path, schema_path: nil)
      migration_content = File.read(migration_path)
      schema_content    = schema_path && File.exist?(schema_path) ? File.read(schema_path) : nil
      new(migration_content, schema_content: schema_content).parse
    end

    def initialize(migration_content, schema_content: nil)
      @migration_content = migration_content
      @schema_content    = schema_content
    end

    def parse
      changes = extract_changes
      schema_tables = @schema_content ? SchemaParser.new(@schema_content).parse[:tables] : []

      after_state  = build_after_state(changes, schema_tables)
      before_state = build_before_state(changes, after_state)
      summary      = build_summary(changes)

      { changes: summary, before: before_state, after: after_state }
    end

    private

    def extract_changes
      changes = []
      @migration_content.each_line do |raw|
        line = raw.strip
        next if line.start_with?("#")

        changes.concat(parse_line(line))
      end
      changes
    end

    def parse_line(line)
      # add_column :table, :column, :type, options
      if (m = line.match(/\badd_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)(.*)/))
        [Change.new(kind: :add_column, table: m[1], column: m[2], type: m[3], options: parse_opts(m[4]))]

      # remove_column :table, :column
      elsif (m = line.match(/\bremove_column\s+:(\w+)\s*,\s*:(\w+)/))
        [Change.new(kind: :remove_column, table: m[1], column: m[2], type: nil, options: {})]

      # rename_column :table, :old, :new
      elsif (m = line.match(/\brename_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)/))
        [Change.new(kind: :rename_column, table: m[1], column: m[2], type: m[3], options: {})]

      # change_column :table, :column, :new_type
      elsif (m = line.match(/\bchange_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)(.*)/))
        [Change.new(kind: :change_column, table: m[1], column: m[2], type: m[3], options: parse_opts(m[4]))]

      # create_table :table
      elsif (m = line.match(/\bcreate_table\s+[:"'](\w+)/))
        [Change.new(kind: :create_table, table: m[1], column: nil, type: nil, options: {})]

      # drop_table :table
      elsif (m = line.match(/\bdrop_table\s+[:"'](\w+)/))
        [Change.new(kind: :drop_table, table: m[1], column: nil, type: nil, options: {})]

      # add_index :table, [:col] or "col"
      elsif (m = line.match(/\badd_index\s+[:"'](\w+)['":]?\s*,\s*(.*)/))
        [Change.new(kind: :add_index, table: m[1], column: m[2], type: nil, options: {})]

      # remove_index :table, column: :col or :col
      elsif (m = line.match(/\bremove_index\s+[:"'](\w+)['":]?\s*,\s*(.*)/))
        [Change.new(kind: :remove_index, table: m[1], column: m[2], type: nil, options: {})]

      else
        []
      end
    end

    def parse_opts(str)
      opts = {}
      opts[:null]    = false  if str.match?(/\bnull:\s*false\b/)
      opts[:null]    = true   if str.match?(/\bnull:\s*true\b/)
      if (m = str.match(/\bdefault:\s*(.+?)(?:,\s*\w+:|$)/))
        opts[:default] = m[1].strip.delete_suffix(",").strip
      end
      opts
    end

    def build_after_state(changes, schema_tables)
      table_map = schema_tables.each_with_object({}) { |t, h| h[t[:name]] = deep_dup_table(t) }

      changes.each do |c|
        case c.kind
        when :add_column
          table_map[c.table] ||= empty_table(c.table)
          table_map[c.table][:columns] << col_from_change(c)
        when :remove_column
          if table_map[c.table]
            table_map[c.table][:columns].reject! { |col| col[:name] == c.column.to_s }
          end
        when :rename_column
          # c.column = old name, c.type = new name
          if table_map[c.table]
            col = table_map[c.table][:columns].find { |col| col[:name] == c.column.to_s }
            col[:name] = c.type.to_s if col
          end
        when :change_column
          if table_map[c.table]
            col = table_map[c.table][:columns].find { |col| col[:name] == c.column.to_s }
            if col
              col[:type]    = c.type.to_s
              col[:nullable] = c.options.fetch(:null, col[:nullable])
              col[:default]  = c.options[:default] if c.options.key?(:default)
            end
          end
        when :create_table
          table_map[c.table] ||= empty_table(c.table)
        when :drop_table
          table_map.delete(c.table)
        end
      end

      table_map
    end

    def build_before_state(changes, after_state)
      before = after_state.transform_values { |t| deep_dup_table(t) }

      # Reverse each change to recover the before state
      changes.reverse_each do |c|
        case c.kind
        when :add_column
          before[c.table]&.dig(:columns)&.reject! { |col| col[:name] == c.column.to_s }
        when :remove_column
          before[c.table] ||= empty_table(c.table)
          # Column type is unknown without the original schema — use "unknown"
          before[c.table][:columns] << { name: c.column.to_s, type: "unknown", nullable: true, default: nil }
        when :rename_column
          # c.column = old, c.type = new; reverse: new → old
          if before[c.table]
            col = before[c.table][:columns].find { |col| col[:name] == c.type.to_s }
            col[:name] = c.column.to_s if col
          end
        when :change_column
          # We don't know the original type without the schema — mark as "unknown"
          if before[c.table]
            col = before[c.table][:columns].find { |col| col[:name] == c.column.to_s }
            col[:type] = "unknown" if col
          end
        when :create_table
          before.delete(c.table)
        when :drop_table
          before[c.table] ||= empty_table(c.table)
        end
      end

      before
    end

    def build_summary(changes)
      changes.map do |c|
        case c.kind
        when :add_column    then { op: "add_column",    table: c.table, column: c.column, type: c.type }
        when :remove_column then { op: "remove_column", table: c.table, column: c.column }
        when :rename_column then { op: "rename_column", table: c.table, from: c.column, to: c.type }
        when :change_column then { op: "change_column", table: c.table, column: c.column, new_type: c.type }
        when :create_table  then { op: "create_table",  table: c.table }
        when :drop_table    then { op: "drop_table",    table: c.table }
        when :add_index     then { op: "add_index",     table: c.table }
        when :remove_index  then { op: "remove_index",  table: c.table }
        end
      end
    end

    def col_from_change(change)
      {
        name:     change.column.to_s,
        type:     change.type.to_s,
        nullable: change.options.fetch(:null, true),
        default:  change.options[:default]
      }
    end

    def empty_table(name)
      { name: name.to_s, columns: [], indexes: [], foreign_keys: [] }
    end

    def deep_dup_table(table)
      {
        name:         table[:name],
        columns:      table[:columns].map(&:dup),
        indexes:      table[:indexes].map(&:dup),
        foreign_keys: table[:foreign_keys].map(&:dup)
      }
    end
  end
end
