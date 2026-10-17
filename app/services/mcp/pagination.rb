module Mcp::Pagination
  MAX_PAGE = 10_000

  module_function

  def normalize_page(value)
    page = Integer(value.presence || 1, exception: false) || 1
    page.clamp(1, MAX_PAGE)
  end
end
