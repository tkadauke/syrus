# Shared page/per-page param parsing for admin- and app-scoped list
# endpoints. Including controllers that offer a caller-set page size must
# define their own `PER_PAGE` constant (used as the default and referenced
# via `self.class::PER_PAGE` so each includer's own value applies).
module Paginatable
  private

  def page_param
    page = params[:page].to_i
    page.positive? ? page : 1
  end

  def per_page_param
    per_page = params[:per_page].to_i
    return self.class::PER_PAGE unless per_page.positive?
    [ per_page, 100 ].min
  end
end
