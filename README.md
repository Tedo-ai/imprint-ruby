# Imprint Ruby Agent

The official Ruby agent for [Imprint](https://imprint.cloud) — a unified observability platform combining Real User Monitoring (RUM), backend tracing, and infrastructure monitoring.

Imprint is being released as **open source**. Learn more at [imprint.cloud](https://imprint.cloud).

## Features

- **Zero-config Rails integration** — automatic instrumentation via Railtie
- **Distributed tracing** — W3C Trace Context propagation across services
- **SQL query tracing** — automatic instrumentation of ActiveRecord queries
- **Background job support** — ActiveJob, Sidekiq, and Delayed::Job
- **Browser integration** — link frontend RUM traces to backend spans
- **Manual instrumentation** — custom spans, events, and attributes
- **Thread-safe batching** — efficient span collection with configurable flush intervals

## Requirements

- Ruby >= 3.0.0
- Rails 6.0+ (optional, for automatic instrumentation)

## Installation

Add to your Gemfile:

```ruby
gem "imprint-ruby", github: "anthropics/imprint-ruby", require: "imprint"
```

Then run:

```bash
bundle install
```

## Quick Start

### Rails

Create an initializer at `config/initializers/imprint.rb`:

```ruby
Imprint.configure do |config|
  config.api_key = ENV["IMPRINT_API_KEY"]
  config.service_name = "my-app"
  config.ingest_url = "https://api.imprint.cloud/v1/spans"
end
```

That's it. The Railtie automatically instruments:
- HTTP requests
- SQL queries
- View rendering
- Background jobs

### Non-Rails

```ruby
require "imprint"

Imprint.configure do |config|
  config.api_key = ENV["IMPRINT_API_KEY"]
  config.service_name = "my-service"
end

# Create spans manually
Imprint.start_span("process_payment") do |span|
  span.set_attribute("order_id", "12345")
  # your code here
end
```

## Configuration

All options can be set via environment variables or Ruby configuration:

```ruby
Imprint.configure do |config|
  # Required
  config.api_key = ENV["IMPRINT_API_KEY"]

  # Service identification
  config.service_name = "web"              # Default: "ruby-app" or Rails app name
  config.job_namespace = "worker"          # Default: same as service_name
  config.ingest_url = "https://api.imprint.cloud/v1/spans"

  # Filtering
  config.ignore_paths = ["/health", "/up"]
  config.ignore_prefixes = ["/assets/", "/packs/"]
  config.ignore_extensions = [".css", ".js", ".png", ".jpg", ".ico"]

  # Batching
  config.batch_size = 100                  # Spans per batch
  config.flush_interval = 5                # Seconds between flushes
  config.buffer_size = 1000                # Max spans in memory

  # Development
  config.debug = Rails.env.development?
  config.enabled = true
end
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `IMPRINT_API_KEY` | API key for authentication |
| `IMPRINT_SERVICE_NAME` | Service name for spans |
| `IMPRINT_JOB_NAMESPACE` | Namespace for background jobs |
| `IMPRINT_INGEST_URL` | Ingest endpoint URL |
| `IMPRINT_DEBUG` | Enable debug logging (`"true"`) |

## Automatic Instrumentation

### HTTP Requests

Every Rails request creates a root span with:

```
Name: "GET /orders/123"
Kind: server
Attributes:
  http.method: GET
  http.url: /orders/123
  http.status_code: 200
  controller: OrdersController
  action: show
  format: html
  db_runtime: 12.5
  view_runtime: 45.2
```

### SQL Queries

ActiveRecord queries create child spans:

```
Name: SELECT
Kind: client
Attributes:
  db.system: postgresql
  db.statement: SELECT * FROM orders WHERE id = $1
  db.name: myapp_production
```

### View Rendering

Template renders create child spans:

```
Name: render orders/show.html.erb
Kind: internal
Attributes:
  template.identifier: app/views/orders/show.html.erb
  template.layout: layouts/application
```

## Manual Instrumentation

### Custom Spans

```ruby
Imprint.start_span("external_api_call", kind: "client") do |span|
  span.set_attribute("api.endpoint", "https://api.stripe.com/v1/charges")
  span.set_attribute("api.method", "POST")

  response = HTTP.post("https://api.stripe.com/v1/charges", body: payload)

  span.set_attribute("api.status", response.status)
  span.set_status(response.status)
end
```

### Custom Attributes

Tag the current span with business context:

```ruby
class OrdersController < ApplicationController
  def show
    @order = Order.find(params[:id])

    Imprint.tag(
      order_id: @order.id,
      customer_id: @order.customer_id,
      order_total: @order.total.to_s,
      item_count: @order.items.count
    )
  end
end
```

### Events

Record instant events (zero-duration spans) for logging and metrics:

```ruby
Imprint.record_event("user.login", attributes: {
  user_id: user.id,
  login_method: "oauth",
  provider: "google"
})

Imprint.record_event("payment.processed", attributes: {
  order_id: order.id,
  amount: order.total.to_s,
  currency: "USD"
})
```

### Action and Namespace

Override the automatic action name or namespace:

```ruby
class DynamicController < ApplicationController
  def handle
    Imprint.set_action("DynamicController##{params[:handler]}")
    Imprint.set_namespace("admin")
    # ...
  end
end
```

### Error Tracking

```ruby
def create
  order = Order.create!(order_params)
rescue ActiveRecord::RecordInvalid => e
  Imprint.send_error(e,
    order_params: order_params.to_h,
    user_id: current_user.id
  )
  render :new, status: :unprocessable_entity
end
```

### Trace Correlation

Access trace IDs for logging correlation:

```ruby
Rails.logger.info "Processing order", trace_id: Imprint.current_trace_id

# Include in API responses for client-side correlation
render json: {
  data: @order,
  meta: { trace_id: Imprint.current_trace_id }
}
```

## Background Jobs

### ActiveJob

Trace context is automatically propagated through job serialization:

```ruby
class ProcessOrderJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    order = Order.find(order_id)

    # This span is a child of the request that enqueued the job
    Imprint.tag(order_id: order.id, customer: order.email)

    # Create child spans for sub-operations
    Imprint.start_span("charge_card") do |span|
      span.set_attribute("amount", order.total.to_s)
      PaymentGateway.charge(order)
    end

    order.process!
  end
end
```

### Sidekiq

Configured automatically when Sidekiq is detected:

```ruby
class HardWorker
  include Sidekiq::Worker

  def perform(order_id)
    # Trace context automatically extracted from job payload
    order = Order.find(order_id)
    Imprint.tag(order_id: order.id)
    # ...
  end
end
```

Span attributes include:
- `messaging.system: sidekiq`
- `messaging.destination: queue_name`
- `sidekiq.job_id`
- `sidekiq.retry`

### Delayed::Job

Configured automatically when Delayed::Job is detected:

```ruby
class Order < ApplicationRecord
  def send_confirmation_email
    # Trace context preserved through YAML serialization
    OrderMailer.confirmation(self).deliver_later
  end
end
```

Span attributes include:
- `messaging.system: delayed_job`
- `delayed_job.id`
- `delayed_job.queue`
- `delayed_job.priority`
- `delayed_job.attempts`

### Separate Namespace for Jobs

Use different namespaces to separate web and worker traffic in the dashboard:

```ruby
Imprint.configure do |config|
  config.service_name = "web"        # HTTP requests
  config.job_namespace = "worker"    # Background jobs
end
```

## Browser Integration

Link frontend Real User Monitoring (RUM) traces to backend spans.

### View Helper

Add trace context meta tags to your layout:

```erb
<!DOCTYPE html>
<html>
<head>
  <%= imprint_meta_tags %>
</head>
```

This outputs:

```html
<meta name="imprint-trace-id" content="abc123...">
<meta name="imprint-span-id" content="def456...">
```

### JavaScript Integration

The [Imprint Browser Agent](https://github.com/anthropics/imprint/tree/main/agents/browser) reads these meta tags automatically and propagates trace context to fetch requests:

```javascript
import { Imprint } from '@imprint/browser';

const imprint = new Imprint({
  publicKey: 'your-public-key',
  serviceName: 'frontend'
});

// Fetch requests automatically include traceparent header
fetch('/api/orders')
  .then(response => response.json());
```

### Manual Context Access

```erb
<script>
  window.TraceContext = {
    traceId: '<%= Imprint.current_trace_id %>',
    spanId: '<%= Imprint.current_span_id %>'
  };
</script>
```

## Distributed Tracing

Imprint supports W3C Trace Context for cross-service trace propagation.

### Incoming Requests

The middleware automatically extracts `traceparent` headers:

```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
```

### Outgoing Requests

Add trace headers to outbound HTTP calls:

```ruby
Imprint.start_span("external_api", kind: "client") do |span|
  headers = {
    "traceparent" => "00-#{span.trace_id}-#{span.span_id}-01"
  }

  HTTP.headers(headers).get("https://api.example.com/resource")
end
```

## Structured Logging

Use `Imprint::Logger` for logs that appear as event spans:

```ruby
class PaymentService
  def initialize
    @logger = Imprint::Logger.new("PaymentService")
  end

  def process(order)
    @logger.info("Processing payment for order #{order.id}")

    result = gateway.charge(order.total)

    if result.success?
      @logger.info("Payment successful", charge_id: result.id)
    else
      @logger.error("Payment failed", error: result.error)
    end
  end
end
```

## API Reference

### Module Methods

```ruby
# Configuration
Imprint.configure { |config| ... }
Imprint.configuration

# Span Management
Imprint.start_span(name, kind: "internal") { |span| ... }
Imprint.record_event(name, attributes: {})

# Current Span Modification
Imprint.tag(key: value, ...)
Imprint.set_action(name)
Imprint.set_namespace(namespace)
Imprint.send_error(exception, **context)

# Context Access
Imprint.current_trace_id
Imprint.current_span_id
Imprint.client

# Lifecycle
Imprint.shutdown(timeout: 5)
```

### Span Methods

```ruby
span.set_attribute(key, value)
span.merge_attributes(hash)
span.set_status(http_status_code)
span.set_name(new_name)
span.set_namespace(new_namespace)
span.record_error(exception)
span.finish  # or span.end
span.root?
```

### View Helpers

```erb
<%= imprint_meta_tags %>
<%= imprint_trace_context %>  # Returns { trace_id:, span_id: }
```

## OpenTelemetry Compatibility

All spans include standard OpenTelemetry SDK metadata:

```
telemetry.sdk.name: imprint-ruby
telemetry.sdk.version: 0.1.0
telemetry.sdk.language: ruby
```

## Troubleshooting

### No spans appearing

1. Check your API key is valid
2. Enable debug mode: `config.debug = true`
3. Verify the ingest URL is reachable
4. Wait for flush interval (default 5 seconds)

### Missing SQL queries

Schema and EXPLAIN queries are filtered by default. Only application queries are traced.

### High memory usage

Reduce buffer size or increase flush frequency:

```ruby
config.buffer_size = 500
config.flush_interval = 2
```

### Jobs not traced

Ensure the job processor is configured:
- ActiveJob: Automatic via Railtie
- Sidekiq: `Imprint::Sidekiq.configure!` (automatic)
- Delayed::Job: `Imprint::DelayedJob.configure!` (automatic)

## Example Application

See the [Rails demo app](demos/rails) for a complete example including:

- Product catalog with SQL tracing
- Checkout flow with trace propagation to background jobs
- Error simulation and recording
- Browser-to-backend trace linking

## Development

```bash
# Clone the repository
git clone https://github.com/anthropics/imprint-ruby.git
cd imprint-ruby

# Install dependencies
bundle install

# Run the demo app
cd demos/rails
bundle install
bin/rails db:setup
bin/rails server
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please read our contributing guidelines before submitting pull requests.

## Links

- [Imprint Platform](https://imprint.cloud)
- [Documentation](https://docs.imprint.cloud)
- [Go Agent](https://github.com/anthropics/imprint-go)
- [Browser Agent](https://github.com/anthropics/imprint/tree/main/agents/browser)
