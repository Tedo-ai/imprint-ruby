class PagesController < ApplicationController
  # GET /shop
  # Tests: Browser-to-backend trace linking via imprint_meta_tags
  def shop
    Imprint.set_action("PagesController#shop")
    Imprint.set_namespace("storefront")

    @products = Product.in_stock.limit(12)
    @recent_orders = Order.recent.limit(5)
  end

  # GET /crash
  # Tests: Error recording and stack trace capture
  def crash
    Imprint.set_action("PagesController#crash")
    Imprint.tag(
      error_simulation: "true",
      test_type: "payment_timeout"
    )

    # Log before crashing
    logger = Imprint::Logger.new("PaymentGateway")
    logger.error("Connection to payment gateway failed after 30s timeout")

    # Simulate a realistic production error
    raise StandardError.new("Payment Gateway Timeout: Connection refused after 30000ms")
  end
end
