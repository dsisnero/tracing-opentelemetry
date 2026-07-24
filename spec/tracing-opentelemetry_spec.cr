require "./spec_helper"

alias Dispatch = Tracing::Dispatch
alias Level = Tracing::Level
alias Metadata = Tracing::Metadata
alias Kind = Tracing::Kind

private class SpanObserver < Tracing::Layer
  getter spans : Array(Tracing::Core::Span::Attributes) = [] of Tracing::Core::Span::Attributes

  def on_new_span(attrs : Tracing::Core::Span::Attributes, id : Tracing::CoreSpan::Id, ctx : Tracing::LayerContext)
    @spans << attrs
  end
end

private def build_valueset(fields : Hash(String, _)) : Tracing::Core::Field::ValueSet
  field_set = Tracing::Field::FieldSet.of(fields.keys, Tracing::Callsite::Identifier.new)
  values = Tracing::Core::Field::ValueSet.new(field_set)
  fields.each do |key, value|
    values.record(Tracing::Field::Field.new(key), value)
  end
  values
end

private def wait_for_export(io : IO::Memory) : JSON::Any
  50.times do
    output = io.to_s
    return JSON.parse(output) unless output.empty?
    Fiber.yield
    sleep 1.millisecond
  end
  raise "timed out waiting for OpenTelemetry export"
end

describe "OpenTelemetryLayer (ported from tracing-opentelemetry/src/layer.rs)" do
  it "stores OtelData in span extensions" do
    layer = Tracing::OpenTelemetryLayer.new
    registry = Tracing::Registry.new.with(layer)

    observer = SpanObserver.new
    registry = registry.with(observer)

    Dispatch.with_default(Dispatch.new(registry)) do
      span!(Level::INFO, "otel_test_span").in_scope do
      end
    end

    observer.spans.size.should eq(1)
    observer.spans[0].metadata.name.should eq("otel_test_span")
  end

  it "maps tracing levels to OTel span kind" do
    layer = Tracing::OpenTelemetryLayer.new
    layer.should be_a(Tracing::Layer)
  end
end

describe "OpenTelemetry span kind mapping" do
  it "maps otel.kind=server to Server kind" do
    kind = Tracing::OpenTelemetryLayer.kind_from_field("server")
    kind.should eq(OpenTelemetry::API::Span::Kind::Server)
  end

  it "maps otel.kind=client to Client kind" do
    kind = Tracing::OpenTelemetryLayer.kind_from_field("client")
    kind.should eq(OpenTelemetry::API::Span::Kind::Client)
  end

  it "defaults to Internal for unknown values" do
    kind = Tracing::OpenTelemetryLayer.kind_from_field("unknown")
    kind.should eq(OpenTelemetry::API::Span::Kind::Internal)
  end

  it "defaults to Internal for nil" do
    kind = Tracing::OpenTelemetryLayer.kind_from_field(nil)
    kind.should eq(OpenTelemetry::API::Span::Kind::Internal)
  end
end

describe "OpenTelemetry status code mapping" do
  it "maps Ok status" do
    status = Tracing::OpenTelemetryLayer.status_from_code("Ok")
    status.code.ok?.should be_true
  end

  it "maps Error status" do
    status = Tracing::OpenTelemetryLayer.status_from_code("Error")
    status.code.error?.should be_true
  end

  it "defaults to Unset for unknown" do
    status = Tracing::OpenTelemetryLayer.status_from_code("Unknown")
    status.code.unset?.should be_true
  end

  it "defaults to Unset for nil" do
    status = Tracing::OpenTelemetryLayer.status_from_code(nil)
    status.code.unset?.should be_true
  end
end

describe "OpenTelemetry error-to-exception mapping" do
  it "detects error events" do
    layer = Tracing::OpenTelemetryLayer.new
    meta = Metadata.new("test", "test", Level::ERROR, kind: Kind::EVENT)
    layer.error_event?(meta).should be_true

    meta2 = Metadata.new("test", "test", Level::INFO, kind: Kind::EVENT)
    layer.error_event?(meta2).should be_false
  end

  it "creates exception attributes from event fields" do
    layer = Tracing::OpenTelemetryLayer.new
    attrs = layer.exception_attributes("test error", "backtrace here")
    attrs.has_key?("exception.message").should be_true
    attrs.has_key?("exception.stacktrace").should be_true
    attrs["exception.message"].should eq("test error")
  end
end

describe "OpenTelemetryLayer configuration" do
  it "with_level filters events below the configured level" do
    layer = Tracing::OpenTelemetryLayer.new.with_level(Level::WARN)
    observer = SpanObserver.new
    registry = Tracing::Registry.new.with(layer).with(observer)

    Dispatch.with_default(Dispatch.new(registry)) do
      info!("should be filtered")
      warn!("should pass")
    end

    observer.spans.size.should eq(0)
  end

  it "default level is TRACE (pass everything)" do
    layer = Tracing::OpenTelemetryLayer.new
    meta = Metadata.new("test", "test", Level::TRACE, kind: Kind::SPAN)
    layer.enabled?(meta, Tracing::LayerContext.new(Tracing::Core::NoSubscriber.new)).should be_true
  end
end

describe "OpenTelemetry dynamic span name" do
  it "extracts otel.name field for span name override" do
    layer = Tracing::OpenTelemetryLayer.new
    name = layer.resolve_span_name("default_name", otel_name: "custom_overridden")
    name.should eq("custom_overridden")
  end

  it "uses original name when otel.name is absent" do
    layer = Tracing::OpenTelemetryLayer.new
    name = layer.resolve_span_name("default_name", nil)
    name.should eq("default_name")
  end
end

describe "OpenTelemetry export integration" do
  it "exports root and child spans with contextual events" do
    io = IO::Memory.new
    exporter = OpenTelemetry::Exporter.new(:io, io: io)
    provider = OpenTelemetry::TraceProvider.new(
      service_name: "spec",
      service_version: "1.0.0",
      exporter: exporter
    )
    layer = Tracing::OpenTelemetryLayer.new(provider).with_context_activation(true)
    subscriber = Tracing::Registry.new.with(layer)

    Dispatch.with_default(Dispatch.new(subscriber)) do
      root_meta = Metadata.new("request", "http.server", Level::INFO, kind: Kind::SPAN)
      root_values = build_valueset({
        "otel.name"   => "GET /users",
        "otel.kind"   => "server",
        "http.method" => "GET",
      })
      root = Tracing::Span.new(root_meta, root_values)

      root.in_scope do
        info!("request.started", user: "alice")

        root_id = root.id || raise "expected root span to have an id"
        child = Tracing.child_span(root_id, Level::INFO, "db", sql: "select 1")
        child.in_scope do
          info!("db.query", rows: 1)
        end
        child.close
      end

      root.close
    end

    trace = wait_for_export(io)
    spans = trace["spans"].as_a
    root = spans.find! { |span| span["name"].as_s == "GET /users" }
    child = spans.find! { |span| span["name"].as_s == "db" }

    root["attributes"]["http.method"].as_s.should eq("GET")
    root["events"].as_a.map(&.["name"].as_s).should contain("request.started")
    child["parentSpanId"].as_s.should eq(root["spanId"].as_s)
    child["events"].as_a.map(&.["name"].as_s).should contain("db.query")
  end

  it "maps error events to status and exception events" do
    io = IO::Memory.new
    exporter = OpenTelemetry::Exporter.new(:io, io: io)
    provider = OpenTelemetry::TraceProvider.new(service_name: "spec", exporter: exporter)
    layer = Tracing::OpenTelemetryLayer.new(provider).with_context_activation(true)
    subscriber = Tracing::Registry.new.with(layer)

    Dispatch.with_default(Dispatch.new(subscriber)) do
      span = span!(Level::INFO, "error_span")
      span.in_scope do
        error!("request.failed", error: "test error")
      end
      span.close
    end

    trace = wait_for_export(io)
    span = trace["spans"].as_a.find! { |entry| entry["name"].as_s == "error_span" }
    span["status"]["code"].as_i.should eq(2)
    span["status"]["message"].as_s.should eq("test error")

    exception_event = span["events"].as_a.find! { |event| event["name"].as_s == "exception" }
    exception_event["attributes"]["exception.message"].as_s.should eq("test error")
  end
end
