# tracing-opentelemetry

Optional OpenTelemetry bridge for
[tracing.cr](https://github.com/dsisnero/tracing.cr).

## Installation

Install with the compatible `tracing.cr` release selected by your application:

```yaml
dependencies:
  tracing:
    github: dsisnero/tracing.cr
    branch: main
  tracing-opentelemetry:
    github: dsisnero/tracing-opentelemetry
```

For local sibling checkout development, switch those entries back to `path:`
dependencies.

## Usage

```crystal
require "tracing"
require "tracing-opentelemetry"

exporter = OpenTelemetry::Exporter.new(:io, io: STDOUT)
provider = OpenTelemetry::TraceProvider.new(
  service_name: "my_app",
  exporter: exporter
)

Tracing::Registry.default
  .with(Tracing::OpenTelemetryLayer.new(provider))
  .init

span!(Tracing::Level::INFO, "request").in_scope do
  info!("request.started")
end
```

## Shipped Surface

- `Tracing::OpenTelemetryLayer`
- OTel span export on close
- contextual event export
- span kind/status/name mapping from tracing fields
- optional current fiber trace/span activation
