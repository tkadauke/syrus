module SyrusRails
  # Line-by-line parser for Rails db/schema.rb files.
  # Handles create_table blocks with column/index declarations,
  # top-level add_index, and top-level add_foreign_key calls.
  # Does not use eval — safe to run on arbitrary schema files.
  class SchemaParser
    COLUMN_TYPES = %w[
      string text integer bigint float decimal boolean date datetime time
      binary blob json jsonb uuid inet cidr macaddr hstore tsvector
      virtual primary_key references
    ].freeze

    def self.parse(path)
      new(File.read(path)).parse
    end

    def initialize(content)
      @content = content
      @tables = {}
      @pending_indexes    = []  # top-level add_index (post-table)
      @pending_fkeys      = []  # top-level add_foreign_key
    end

    def parse
      current_table = nil

      @content.each_line do |raw|
        line = raw.strip

        if (m = line.match(/\bcreate_table\s+["'](\w+)["']/))
          current_table = m[1]
          @tables[current_table] ||= { name: current_table, columns: [], indexes: [], foreign_keys: [] }

        elsif line =~ /\bend\b/ && current_table && !line.match?(/\bdo\b/)
          current_table = nil

        elsif current_table
          parse_column(line, current_table)
          parse_inline_index(line, current_table)

        else
          parse_top_level_index(line)
          parse_top_level_fkey(line)
        end
      end

      apply_top_level_indexes
      apply_top_level_fkeys

      { tables: @tables.values }
    end

    private

    def parse_column(line, table_name)
      # t.string "name", null: false, default: "x"
      # t.integer :count, default: 0
      pattern = /\bt\.(#{COLUMN_TYPES.join("|")})\s+["':]*(\w+)["']?(.*)$/
      m = line.match(pattern)
      return unless m

      col_type    = m[1]
      col_name    = m[2]
      rest        = m[3]

      nullable = !rest.match?(/\bnull:\s*false\b/)
      default  = extract_default(rest)

      @tables[table_name][:columns] << {
        name:     col_name,
        type:     col_type,
        nullable: nullable,
        default:  default
      }
    end

    def parse_inline_index(line, table_name)
      # t.index ["col1", "col2"], name: "idx_name", unique: true
      m = line.match(/\bt\.index\s+(.+)$/)
      return unless m

      @tables[table_name][:indexes] << parse_index_args(m[1])
    end

    def parse_top_level_index(line)
      # add_index "table", ["col1"], name: "idx_name", unique: true
      m = line.match(/\badd_index\s+["'](\w+)["']\s*,\s*(.+)$/)
      return unless m

      @pending_indexes << { table: m[1], args: m[2] }
    end

    def parse_top_level_fkey(line)
      # add_foreign_key "from_table", "to_table", column: "col_id", primary_key: "id"
      m = line.match(/\badd_foreign_key\s+["'](\w+)["']\s*,\s*["'](\w+)["'](.*)$/)
      return unless m

      from_table = m[1]
      to_table   = m[2]
      rest       = m[3]

      col_m  = rest.match(/column:\s*["':]*(\w+)/)
      pk_m   = rest.match(/primary_key:\s*["':]*(\w+)/)

      from_column = col_m ? col_m[1] : "#{to_table.sub(/s$/, "")}_id"
      to_column   = pk_m  ? pk_m[1]  : "id"

      @pending_fkeys << { from_table: from_table, to_table: to_table, from_column: from_column, to_column: to_column }
    end

    def apply_top_level_indexes
      @pending_indexes.each do |pi|
        next unless @tables.key?(pi[:table])

        @tables[pi[:table]][:indexes] << parse_index_args(pi[:args])
      end
    end

    def apply_top_level_fkeys
      @pending_fkeys.each do |fk|
        next unless @tables.key?(fk[:from_table])

        @tables[fk[:from_table]][:foreign_keys] << {
          from_column: fk[:from_column],
          to_table:    fk[:to_table],
          to_column:   fk[:to_column]
        }
      end
    end

    def parse_index_args(args_str)
      cols   = extract_string_array(args_str)
      name_m = args_str.match(/name:\s*["']([^"']+)["']/)
      unique = args_str.match?(/unique:\s*true/)

      { name: name_m ? name_m[1] : nil, columns: cols, unique: unique }
    end

    def extract_string_array(str)
      # ["col1", "col2"] or "col1" or :col1
      if (m = str.match(/\[([^\]]+)\]/))
        m[1].scan(/["':]*(\w+)["']?/).flatten
      elsif (m = str.match(/\A\s*["':]*(\w+)/))
        [m[1]]
      else
        []
      end
    end

    def extract_default(rest)
      m = rest.match(/default:\s*(.+?)(?:,\s*\w+:|$)/)
      return nil unless m

      val = m[1].strip.delete_suffix(",").strip
      return nil if val == "nil"

      # Strip surrounding quotes for string defaults
      if (s = val.match(/\A["'](.*)["']\z/))
        s[1]
      else
        val
      end
    end
  end
end
