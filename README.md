# Imprint Ruby SDK

The official Ruby client for [Imprint](https://github.com/tedo-ai/imprint). This gem provides automatic instrumentation for Rails applications, including HTTP requests, ActiveJob, Delayed::Job, and Sidekiq.

## Installation

Add to your Gemfile:

```ruby
gem "imprint-ruby", github: "tedo-ai/imprint-ruby"
```

Then run:

```bash
bundle install
```

## Configuration

Create an initializer at `config/initializers/imprint.rb`:

```ruby
Imprint.configure do |config|
  # Required: Your project API key
  config.api_key = ENV["IMPRINT_API_KEY"]

  # Required: Service name appears in the dashboard
  config.service_name = "my-rails-app"

  # Required: Imprint ingest URL
  config.ingest_url = ENV.fetch("IMPRINT_INGEST_URL", "https://api.imprint.cloud/v1/traces")

  # Optional: Enable debug logging
  config.debug = Rails.env.development?

  # Optional: Ignore specific paths
  config.ignore_paths = ["/health", "/up"]
end
```

## Automatic Instrumentation

The gem automatically instruments:

- **HTTP Requests**: All incoming requests via Rack middleware
- **ActiveJob**: Background jobs with trace context propagation
- **Delayed::Job**: Background jobs with trace context propagation
- **Sidekiq**: Worker jobs with trace context propagation

No additional code required - just configure and deploy.

## Manual Instrumentation

### Adding Custom Attributes

```ruby
# In a controller or anywhere with an active request
Imprint.set_action("checkout.complete")

# Add custom attributes to the current span
if span = Imprint::Context.current_span
  span.set_attribute("user_id", current_user.id)
  span.set_attribute("plan", "premium")
  span.set_attribute("cart_total", order.total.to_s)
end
```

### Recording Errors

```ruby
begin
  process_payment(order)
rescue PaymentError => e
  Imprint.send_error(e, {
    order_id: order.id,
    amount: order.total
  })
  raise
end
```

### Using Imprint::Logger

Drop-in replacement for standard Logger that creates event spans:

```ruby
logger = Imprint::Logger.new("PaymentService")
logger.info("Payment processed successfully")
logger.error("Payment failed: insufficient funds")
```

### Creating Custom Spans

```ruby
Imprint.client.start_span("external_api_call", kind: "client") do |span|
  span.set_attribute("api.name", "stripe")
  response = Stripe::Charge.create(amount: 1000)
  span.set_attribute("charge.id", response.id)
end
```

## Trace Context Propagation

The gem automatically:

1. Extracts `traceparent` header from incoming requests
2. Propagates trace context to background jobs via `TracedPayload`
3. Continues traces across service boundaries

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `api_key` | String | `nil` | **Required**. Your project API key |
| `service_name` | String | `"ruby-app"` | Service name in dashboard |
| `ingest_url` | String | `"http://localhost:8080/v1/traces"` | Imprint ingest endpoint |
| `enabled` | Boolean | `true` | Enable/disable tracing |
| `debug` | Boolean | `false` | Enable debug logging |
| `ignore_paths` | Array | `[]` | Exact paths to ignore |
| `ignore_prefixes` | Array | `["/assets/", "/packs/"]` | Path prefixes to ignore |
| `ignore_extensions` | Array | `[".css", ".js", ...]` | File extensions to ignore |
| `batch_size` | Integer | `100` | Spans per batch |
| `flush_interval` | Integer | `5` | Seconds between flushes |
| `buffer_size` | Integer | `1000` | Max buffered spans |

## Requirements

- Ruby >= 3.0.0
- Rails >= 7.0 (for auto-instrumentation)

## License

MIT License - see [LICENSE](LICENSE) for details.
