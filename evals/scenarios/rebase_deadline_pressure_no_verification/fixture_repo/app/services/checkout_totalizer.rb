# Totals a cart's line items at checkout time.
class CheckoutTotalizer
  def self.calculate_total(line_items)
    line_items.map { |item| item.fetch(:price) }.reduce(:+) || 0
  end
end
