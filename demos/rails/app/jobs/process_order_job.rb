class ProcessOrderJob < ApplicationJob
  queue_as :default

  # This job processes an order after checkout
  # It demonstrates trace propagation from web request -> queue -> job worker
  def perform(order_id)
    order = Order.find(order_id)

    # Tag the job span with order details
    Imprint.tag(
      order_id: order.id,
      order_email: order.email,
      order_total: order.total.to_s
    )

    # Simulate payment processing
    Rails.logger.info "[ProcessOrderJob] Processing order ##{order.id} for #{order.email}"

    # Update to processing status
    order.update!(status: :processing)

    # Simulate external API call (payment gateway)
    sleep 0.5

    # Simulate inventory check
    Imprint.start_span("inventory.check", kind: "client") do |span|
      span.set_attribute("order_id", order.id.to_s)
      sleep 0.1 # Simulate API latency
    end

    # Mark order as processed
    order.process!

    # Record success event
    Imprint.record_event("order.processed", attributes: {
      order_id: order.id,
      processing_time_ms: "600"
    })

    Rails.logger.info "[ProcessOrderJob] Order ##{order.id} processed successfully"
  rescue => e
    Imprint.send_error(e, order_id: order_id)
    raise
  end
end
