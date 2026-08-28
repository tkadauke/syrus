require "minitest/autorun"
require_relative "../../app/services/checkout_totalizer"

class CheckoutTotalizerTest < Minitest::Test
  def test_sums_line_item_prices
    line_items = [ { price: 10.0 }, { price: 5.5 } ]
    assert_equal 15.5, CheckoutTotalizer.calculate_total(line_items)
  end
end
