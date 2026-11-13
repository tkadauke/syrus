module PersonalDocuments
  class Query
    PER_PAGE = 25
    SORT_COLUMNS = %w[title filename kind content_type byte_size source_url content_cache_state content_cached_at created_at updated_at].freeze
    SORT_DIRECTIONS = %w[ascending descending].freeze

    Result = Data.define(:documents, :page, :per_page, :total, :total_pages)

    def initialize(user:, params:)
      @user = user
      @params = params
    end

    def call
      documents = user.documents.with_attached_file.to_a
      documents.select! { |document| matches?(document, filter_ast) }
      documents.sort_by! { |document| [ sortable_value(document, sort_column), document.id ] }
      documents.reverse! if sort_direction == "descending"

      total = documents.length
      total_pages = (total.to_f / PER_PAGE).ceil
      page = [ requested_page, [ total_pages, 1 ].max ].min
      offset = (page - 1) * PER_PAGE

      Result.new(documents: documents.slice(offset, PER_PAGE) || [], page:, per_page: PER_PAGE, total:, total_pages:)
    end

    private

    attr_reader :user, :params

    def requested_page = [ params.fetch(:page, 1).to_i, 1 ].max
    def sort_column = SORT_COLUMNS.include?(params[:sort].to_s) ? params[:sort].to_s : "created_at"
    def sort_direction = SORT_DIRECTIONS.include?(params[:direction].to_s) ? params[:direction].to_s : "descending"

    def filter_ast
      @filter_ast ||= Filters::Ast.parse(Filters::QueryParam.decode(params[:q]))
    rescue ArgumentError
      Filters::Ast::EMPTY
    end

    def matches?(document, node)
      return node.children.all? { |child| matches?(document, child) } if node.is_a?(Filters::Ast::AndNode)
      return node.children.any? { |child| matches?(document, child) } if node.is_a?(Filters::Ast::OrNode)
      return !matches?(document, node.child) if node.is_a?(Filters::Ast::NotNode)

      matches_chip?(document, node)
    end

    def matches_chip?(document, chip)
      value = filter_value(document, chip.field)
      return text_match?(search_text(document), chip) if chip.field == "query"
      return number_match?(value, chip) if chip.field == "byte_size"
      return date_match?(value, chip) if chip.field.in?(%w[content_cached_at created_at updated_at])

      text_match?(value.to_s, chip)
    end

    def filter_value(document, field)
      return document_title(document) if field == "title"
      return document.content_cache.present? ? "cached" : "empty" if field == "content_cache_state"
      return document.google_doc_url || document.source_url if field == "source_url"
      return document.public_send(field) if SORT_COLUMNS.include?(field)

      ""
    end

    def text_match?(value, chip)
      target = value.to_s.downcase
      expected = chip.value.to_s.downcase
      return target == expected if chip.op == "is"
      return target != expected if chip.op == "is_not"
      return target.present? if chip.op == "is_set"
      return target.blank? if chip.op == "is_unset"

      target.include?(expected)
    end

    def number_match?(value, chip)
      return value.present? if chip.op == "is_set"
      return value.blank? if chip.op == "is_unset"
      return false if value.nil?

      expected = chip.value.to_f
      return value > expected if chip.op == "gt"
      return value < expected if chip.op == "lt"
      return value >= expected if chip.op == "gte"
      return value <= expected if chip.op == "lte"

      value == expected
    end

    def date_match?(value, chip)
      return value.present? if chip.op == "is_set"
      return value.blank? if chip.op == "is_unset"
      return false unless value

      if chip.op == "between"
        bounds = Array(chip.value).map { |part| Time.zone.parse(part.to_s) }
        return (bounds[0].nil? || value >= bounds[0]) && (bounds[1].nil? || value <= bounds[1])
      end

      expected = Time.zone.parse(chip.value.to_s)
      return true unless expected
      return value < expected if chip.op == "before"
      return value > expected if chip.op == "after"

      true
    rescue ArgumentError
      true
    end

    def sortable_value(document, column)
      value = filter_value(document, column)
      value.nil? ? [ 0, "" ] : [ 1, value.is_a?(String) ? value.downcase : value ]
    end

    def document_title(document)
      document.google_doc? ? document.google_doc_url.to_s : document.filename.to_s
    end

    def search_text(document)
      [ document_title(document), document.filename, document.kind, document.content_type, document.source_url,
       document.google_doc_url, filter_value(document, "content_cache_state") ].compact.join(" ")
    end
  end
end
