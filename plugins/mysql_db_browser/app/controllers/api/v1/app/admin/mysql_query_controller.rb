module Api
  module V1
    module App
      module Admin
        class MysqlQueryController < BaseController
          before_action :require_mysql_db_browser_enabled
          before_action :set_connection

          MAX_PER_PAGE = 200
          DEFAULT_PER_PAGE = 50

          # Raw SQL - the Query tab, and the Live-diagnostics tab's canned
          # system-table SELECTs.
          def execute
            render json: executor.execute(params.dig(:mysql_query, :sql), user: Current.user)
          rescue ::MysqlDbBrowser::QueryExecutor::BlankStatement => e
            render_error("blank_statement", e.message, status: :unprocessable_content)
          rescue ::MysqlDbBrowser::QueryExecutor::WriteNotAllowed => e
            render_error("write_not_allowed", e.message, status: :forbidden)
          rescue ::MysqlDbBrowser::QueryExecutor::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          end

          # Grid-first Content tab: builds a SELECT from the table's
          # introspected columns, an optional FilterBar filter tree, sort,
          # and pagination - then runs it through the same guardrailed
          # executor as raw queries.
          def content
            table_payload = schema_inspector.table(params[:database], params[:table])
            columns = table_payload.dig(:columns, :available) ? table_payload[:columns][:rows] : []
            filter_schema = ::MysqlDbBrowser::FilterSchemaBuilder.build(columns)
            filter_tree = ::Filters::QueryParam.decode(params[:q])
            sort_column = sortable_column(columns, params[:sort_by])
            sort_direction = params[:sort_dir].to_s.downcase == "desc" ? "DESC" : "ASC"
            per_page = clamp_per_page(params[:per_page])
            page = [ params[:page].to_i, 1 ].max
            offset = (page - 1) * per_page

            result = executor.execute_select(user: Current.user, limit: per_page + 1) do |client|
              build_select(client: client, filter_tree: filter_tree, filter_schema: filter_schema, sort_column: sort_column, sort_direction: sort_direction, per_page: per_page, offset: offset)
            end

            has_more = result[:available] && result[:rows].length > per_page
            result = result.merge(rows: result[:rows].first(per_page)) if has_more

            render json: result.merge(filter_schema: filter_schema, filter: filter_tree, page: page, per_page: per_page, has_more: has_more)
          rescue ::MysqlDbBrowser::SchemaInspector::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          rescue ::MysqlDbBrowser::SchemaInspector::NotFound => e
            render_error("not_found", e.message, status: :not_found)
          rescue ::MysqlDbBrowser::QueryExecutor::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          rescue ::MysqlDbBrowser::FilterTreeSqlCompiler::UnknownField, ::MysqlDbBrowser::FilterTreeSqlCompiler::UnsupportedOperator => e
            render_error("invalid_filter", e.message, status: :unprocessable_content)
          end

          private

          def executor
            @executor ||= ::MysqlDbBrowser::QueryExecutor.new(@connection)
          end

          def schema_inspector
            @schema_inspector ||= ::MysqlDbBrowser::SchemaInspector.new(@connection)
          end

          def build_select(client:, filter_tree:, filter_schema:, sort_column:, sort_direction:, per_page:, offset:)
            where_clause = filter_tree.present? ? ::MysqlDbBrowser::FilterTreeSqlCompiler.new(client: client, filter_schema: filter_schema).compile(filter_tree) : nil
            sql = +"SELECT * FROM #{quote_identifier(params[:database])}.#{quote_identifier(params[:table])}"
            sql << " WHERE #{where_clause}" if where_clause.present?
            sql << " ORDER BY #{quote_identifier(sort_column)} #{sort_direction}" if sort_column
            sql << " LIMIT #{per_page + 1} OFFSET #{offset}"
            sql
          end

          def quote_identifier(name)
            "`#{name.to_s.gsub('`', '``')}`"
          end

          def sortable_column(columns, requested)
            names = columns.map { |column| column[:name] }
            names.find { |name| name == requested } || names.first
          end

          def clamp_per_page(value)
            raw = value.presence&.to_i || DEFAULT_PER_PAGE
            [ [ raw, 1 ].max, MAX_PER_PAGE ].min
          end

          def set_connection
            @connection = MysqlConnection.find(params[:id])
          end

          def require_mysql_db_browser_enabled
            return if ::MysqlDbBrowser.enabled?

            render_error("plugin_disabled", "The mysql_db_browser plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
