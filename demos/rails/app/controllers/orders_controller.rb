class OrdersController < ApplicationController
  # POST /checkout or POST /orders
  # Tests: Trace propagation from web request -> Delayed::Job -> ProcessOrderJob
  def create
    Imprint.set_action("OrdersController#create")
    Imprint.set_namespace("checkout")

    # Simulate cart total calculation
    total = params[:total].presence || rand(50..500)
    email = params[:email].presence || "customer@example.com"
    items = params[:items].presence || generate_random_items

    Imprint.tag(
      checkout_total: total.to_s,
      customer_email: email,
      item_count: items.is_a?(Array) ? items.size.to_s : "1"
    )

    # Create the order
    @order = Order.create!(
      email: email,
      total: total,
      items: items.to_json,
      status: :pending
    )

    Rails.logger.info "[Checkout] Created order ##{@order.id}"

    # Enqueue background job for processing
    # This is where trace context propagation happens!
    ProcessOrderJob.perform_later(@order.id)

    Imprint.record_event("order.enqueued", attributes: {
      order_id: @order.id,
      queue: "default"
    })

    respond_to do |format|
      format.html { redirect_to shop_path, notice: "Order ##{@order.id} created! Processing..." }
      format.json { render json: { order_id: @order.id, status: @order.status }, status: :created }
    end
  end

  private

  def generate_random_items
    Product.order("RANDOM()").limit(rand(1..5)).pluck(:id).map do |id|
      { product_id: id, quantity: rand(1..3) }
    end
  end
end
