require "opentelemetry-api"
require "opentelemetry-sdk"

module Tracing
  class OpenTelemetryLayer < Layer
    @level : LevelFilter
    @provider : OpenTelemetry::TraceProvider
    @show_target : Bool
    @show_location : Bool
    @show_threads : Bool
    @context_activation : Bool
    @tracked_inactivity : Bool
    @error_events_to_status : Bool
    @error_events_to_exceptions : Bool
    @error_fields_to_exceptions : Bool
    @error_records_to_exceptions : Bool

    def initialize(source : OpenTelemetry::TraceProvider | OpenTelemetry::Trace = OpenTelemetry.tracer_provider)
      @provider = source.is_a?(OpenTelemetry::Trace) ? source.provider : source
      @level = LevelFilter.trace
      @show_target = true
      @show_location = false
      @show_threads = false
      @context_activation = true
      @tracked_inactivity = false
      @error_events_to_status = true
      @error_events_to_exceptions = true
      @error_fields_to_exceptions = true
      @error_records_to_exceptions = true
    end

    def with_tracer(tracer : OpenTelemetry::Trace) : self
      @provider = tracer.provider
      self
    end

    def with_level(level : Level) : self
      @level = LevelFilter.from_level(level)
      self
    end

    def with_target(show : Bool) : self
      @show_target = show
      self
    end

    def with_location(show : Bool) : self
      @show_location = show
      self
    end

    def with_threads(show : Bool) : self
      @show_threads = show
      self
    end

    def with_context_activation(enabled : Bool) : self
      @context_activation = enabled
      self
    end

    def with_tracked_inactivity(enabled : Bool) : self
      @tracked_inactivity = enabled
      self
    end

    def with_error_events_to_status(enabled : Bool) : self
      @error_events_to_status = enabled
      self
    end

    def with_error_events_to_exceptions(enabled : Bool) : self
      @error_events_to_exceptions = enabled
      self
    end

    def with_error_fields_to_exceptions(enabled : Bool) : self
      @error_fields_to_exceptions = enabled
      self
    end

    def with_error_records_to_exceptions(enabled : Bool) : self
      @error_records_to_exceptions = enabled
      self
    end

    def enabled?(meta : Metadata, ctx : LayerContext) : Bool
      meta.level <= @level
    end

    def max_level_hint : LevelFilter?
      @level
    end

    def on_new_span(attrs : Core::Span::Attributes, id : Core::Span::Id, ctx : LayerContext) : Nil
      return unless span_ref = ctx.span(id)
      return unless exts = span_ref.extensions_mut

      data = build_span_data(attrs.metadata, span_ref)
      apply_span_fields(data, attrs.values, emit_exception: @error_fields_to_exceptions)
      exts.insert(data)
    end

    def on_record(id : Core::Span::Id, values : Core::Span::Record, ctx : LayerContext) : Nil
      return unless data = span_data(ctx, id)
      apply_span_fields(data, values.values, emit_exception: @error_records_to_exceptions)
    end

    def on_enter(id : Core::Span::Id, ctx : LayerContext) : Nil
      return unless @context_activation
      return unless data = span_data(ctx, id)

      data.push_activation(OpenTelemetry::Trace.current_trace, OpenTelemetry.current_span)
      Fiber.current.current_trace = data.trace
      Fiber.current.current_span = data.span
    end

    def on_exit(id : Core::Span::Id, ctx : LayerContext) : Nil
      return unless @context_activation
      return unless data = span_data(ctx, id)

      if snapshot = data.pop_activation
        Fiber.current.current_trace = snapshot.trace
        Fiber.current.current_span = snapshot.span
      else
        Fiber.current.current_trace = nil
        Fiber.current.current_span = nil
      end
    end

    def on_event(event : Core::Event, ctx : LayerContext) : Nil
      return unless span_ref = ctx.event_span(event)
      return unless data = span_ref.extensions.try(&.get(OtelSpanData))

      event_data = extract_fields(event.values)
      add_metadata_attributes(event_data.attributes, event.metadata)

      data.span.add_event(event.metadata.name) do |otel_event|
        event_data.attributes.each do |key, value|
          otel_event[key] = value
        end
      end

      if error_event?(event.metadata)
        if @error_events_to_status
          data.span.status.error!(event_data.error_message || event.metadata.name)
        end
        if @error_events_to_exceptions
          add_exception_event(data.span, event_data)
        end
      end
    end

    def on_record_follows_from(span : Core::Span::Id, follows : Core::Span::Id, ctx : LayerContext) : Nil
      return unless span_data = span_data(ctx, span)
      return unless follows_data = span_data(ctx, follows)

      span_data.follows_from << follows_data.span.context.span_id.hexstring
      span_data.span["tracing.follows_from"] = span_data.follows_from.dup
    end

    def on_close(id : Core::Span::Id, ctx : LayerContext) : Nil
      return unless data = span_data(ctx, id)
      return if data.closed?

      data.closed = true
      data.span.finish = OpenTelemetry.clock.monotonic
      data.span.wall_finish = OpenTelemetry.clock.utc
      data.parent_span.try { |parent| parent.children << data.span }
      data.trace.output_stack.unshift(data.span) if data.span.can_export?

      return unless data.trace_owner?
      if exporter = data.trace.exporter
        exporter.export(data.trace)
      end
    end

    def self.kind_from_field(name : String?) : OpenTelemetry::API::Span::Kind
      case name.try(&.downcase)
      when "server"   then OpenTelemetry::API::Span::Kind::Server
      when "client"   then OpenTelemetry::API::Span::Kind::Client
      when "producer" then OpenTelemetry::API::Span::Kind::Producer
      when "consumer" then OpenTelemetry::API::Span::Kind::Consumer
      else                 OpenTelemetry::API::Span::Kind::Internal
      end
    end

    def self.status_from_code(code : String?) : OpenTelemetry::API::Status
      status = OpenTelemetry::API::Status.new
      status.code = case code.try(&.downcase)
                    when "ok"    then OpenTelemetry::API::AbstractStatus::StatusCode::Ok
                    when "error" then OpenTelemetry::API::AbstractStatus::StatusCode::Error
                    else              OpenTelemetry::API::AbstractStatus::StatusCode::Unset
                    end
      status
    end

    def error_event?(meta : Metadata) : Bool
      meta.level == Level::ERROR
    end

    def exception_attributes(message : String, stacktrace : String) : Hash(String, String)
      {
        "exception.message"    => message,
        "exception.stacktrace" => stacktrace,
      }
    end

    def resolve_span_name(default : String, otel_name : String?) : String
      otel_name || default
    end

    private def build_span_data(meta : Metadata, span_ref : SpanRef) : OtelSpanData
      parent_data = span_ref.parent.try(&.extensions).try(&.get(OtelSpanData))
      parent_span = parent_data.try(&.span)
      trace_owner = false

      trace = if existing_trace = parent_data.try(&.trace)
                existing_trace
              elsif @context_activation && (active_trace = OpenTelemetry::Trace.current_trace) && (active_span = OpenTelemetry.current_span)
                parent_span ||= active_span
                active_trace
              else
                trace_owner = true
                @provider.trace
              end

      span = OpenTelemetry::Span.new(meta.name)
      span.context = build_span_context(trace, parent_span)
      span.parent = parent_span
      if trace_owner
        api_ctx = span.context
        trace.span_context = OpenTelemetry::SpanContext.new(
          api_ctx.trace_id, api_ctx.span_id, api_ctx.parent_id,
          api_ctx.trace_flags, api_ctx.trace_state, api_ctx.remote)
      end

      add_metadata_attributes(span.attributes, meta)

      OtelSpanData.new(trace: trace, span: span, parent_span: parent_span, trace_owner: trace_owner)
    end

    private def build_span_context(trace : OpenTelemetry::Trace, parent_span : OpenTelemetry::Span?) : OpenTelemetry::API::SpanContext
      sdk_ctx = if parent_span
                  api_ctx = parent_span.context
                  sdk_parent = OpenTelemetry::SpanContext.new(
                    api_ctx.trace_id, api_ctx.span_id, api_ctx.parent_id,
                    api_ctx.trace_flags, api_ctx.trace_state, api_ctx.remote)
                  OpenTelemetry::SpanContext.build(sdk_parent) do |config|
                    config.span_id = trace.provider.id_generator.span_id
                  end
                else
                  OpenTelemetry::SpanContext.build do |config|
                    config.trace_id = trace.trace_id
                    config.span_id = trace.provider.id_generator.span_id
                    config.trace_flags = OpenTelemetry::TraceFlags::Sampled
                    config.trace_state = trace.span_context.trace_state
                  end
                end
      OpenTelemetry::API::SpanContext.new(
        sdk_ctx.trace_id, sdk_ctx.span_id, sdk_ctx.parent_id,
        sdk_ctx.trace_flags, sdk_ctx.trace_state, sdk_ctx.remote)
    end

    private def span_data(ctx : LayerContext, id : Core::Span::Id) : OtelSpanData?
      ctx.span(id).try(&.extensions).try(&.get(OtelSpanData))
    end

    private def apply_span_fields(data : OtelSpanData, values : Core::Field::ValueSet, emit_exception : Bool) : Nil
      extracted = extract_fields(values)
      span = data.span

      extracted.attributes.each do |key, value|
        span[key] = value
      end

      span.name = resolve_span_name(span.name, extracted.otel_name)
      span.kind = self.class.kind_from_field(extracted.otel_kind)
      apply_status(span, extracted.otel_status_code, extracted.otel_status_description)

      return unless emit_exception
      return unless extracted.exception_message

      add_exception_event(span, extracted)
      span.status.error!(extracted.error_message || extracted.exception_message)
    end

    private def apply_status(span : OpenTelemetry::Span, code : String?, description : String?) : Nil
      case self.class.status_from_code(code).code
      when .ok?
        span.status.ok!(description)
      when .error?
        span.status.error!(description || span.status.message)
      else
        span.status.message = description if description
      end
    end

    private def extract_fields(values : Core::Field::ValueSet) : ExtractedFields
      visitor = OTelFieldVisitor.new
      values.visit(visitor)
      visitor.into_fields
    end

    private def add_exception_event(span : OpenTelemetry::Span, fields : ExtractedFields) : Nil
      message = fields.exception_message || fields.error_message || ""
      stacktrace = fields.exception_stacktrace || ""

      span.add_event("exception") do |event|
        attrs = exception_attributes(message, stacktrace)
        attrs.each do |key, value|
          event[key] = value
        end
      end
    end

    private def add_metadata_attributes(attributes : Hash(String, OpenTelemetry::AnyAttribute), meta : Metadata) : Nil
      attributes["tracing.level"] = OpenTelemetry::AnyAttribute.new(key: "tracing.level", value: meta.level.as_str)
      if @show_target
        attributes["tracing.target"] = OpenTelemetry::AnyAttribute.new(key: "tracing.target", value: meta.target)
      end
      if @show_location
        if file = meta.file
          attributes["code.filepath"] = OpenTelemetry::AnyAttribute.new(key: "code.filepath", value: file)
        end
        if line = meta.line
          attributes["code.lineno"] = OpenTelemetry::AnyAttribute.new(key: "code.lineno", value: line.to_i64)
        end
      end
      return unless @show_threads

      attributes["thread.id"] = OpenTelemetry::AnyAttribute.new(key: "thread.id", value: Fiber.current.object_id.to_s)
      if name = Fiber.current.name
        attributes["thread.name"] = OpenTelemetry::AnyAttribute.new(key: "thread.name", value: name)
      end
    end

    private def add_metadata_attributes(attributes : Hash(String, OpenTelemetry::ValueType), meta : Metadata) : Nil
      attributes["tracing.level"] = meta.level.as_str
      attributes["tracing.target"] = meta.target if @show_target
      if @show_location
        if file = meta.file
          attributes["code.filepath"] = file
        end
        if line = meta.line
          attributes["code.lineno"] = line.to_i64
        end
      end
      return unless @show_threads

      attributes["thread.id"] = Fiber.current.object_id.to_s
      if name = Fiber.current.name
        attributes["thread.name"] = name
      end
    end
  end

  class OtelSpanData
    getter trace : OpenTelemetry::Trace
    getter span : OpenTelemetry::Span
    getter parent_span : OpenTelemetry::Span?
    getter? trace_owner : Bool
    getter follows_from : Array(String)
    property? closed : Bool
    @activation_stack : Array(ActivationSnapshot)

    def initialize(@trace : OpenTelemetry::Trace, @span : OpenTelemetry::Span, @parent_span : OpenTelemetry::Span?, @trace_owner : Bool)
      @closed = false
      @follows_from = [] of String
      @activation_stack = [] of ActivationSnapshot
    end

    def push_activation(trace : OpenTelemetry::Trace?, span : OpenTelemetry::Span?) : Nil
      @activation_stack << ActivationSnapshot.new(trace, span)
    end

    def pop_activation : ActivationSnapshot?
      @activation_stack.pop?
    end
  end

  private record ActivationSnapshot, trace : OpenTelemetry::Trace?, span : OpenTelemetry::Span?

  private record ExtractedFields,
    attributes : Hash(String, OpenTelemetry::ValueType),
    otel_name : String?,
    otel_kind : String?,
    otel_status_code : String?,
    otel_status_description : String?,
    exception_message : String?,
    exception_stacktrace : String?,
    error_message : String?

  private class OTelFieldVisitor
    include Core::Field::Visit

    def initialize
      @attributes = {} of String => OpenTelemetry::ValueType
      @otel_name = nil
      @otel_kind = nil
      @otel_status_code = nil
      @otel_status_description = nil
      @exception_message = nil
      @exception_stacktrace = nil
      @error_message = nil
    end

    def record_debug(field : Field::Field, value) : Nil
      record_scalar(field.name, value.to_s)
    end

    def record_i64(field : Field::Field, value : Int64) : Nil
      record_scalar(field.name, value)
    end

    def record_u64(field : Field::Field, value : UInt64) : Nil
      record_scalar(field.name, value.to_i64)
    end

    def record_f64(field : Field::Field, value : Float64) : Nil
      record_scalar(field.name, value)
    end

    def record_bool(field : Field::Field, value : Bool) : Nil
      record_scalar(field.name, value)
    end

    def record_str(field : Field::Field, value : String) : Nil
      record_scalar(field.name, value)
    end

    def record_error(field : Field::Field, value : Exception) : Nil
      message = value.message || value.class.name
      @exception_message = message
      @exception_stacktrace = value.backtrace.join("\n")
      @error_message = message
      record_scalar(field.name, message)
    end

    def into_fields : ExtractedFields
      ExtractedFields.new(
        attributes: @attributes,
        otel_name: @otel_name,
        otel_kind: @otel_kind,
        otel_status_code: @otel_status_code,
        otel_status_description: @otel_status_description,
        exception_message: @exception_message,
        exception_stacktrace: @exception_stacktrace,
        error_message: @error_message
      )
    end

    private def record_scalar(name : String, value : OpenTelemetry::ValueType) : Nil
      case name
      when "otel.name"
        @otel_name = value.to_s
      when "otel.kind"
        @otel_kind = value.to_s
      when "otel.status_code"
        @otel_status_code = value.to_s
      when "otel.status_description"
        @otel_status_description = value.to_s
      else
        @attributes[name] = value
        if name == "error"
          @error_message = value.to_s
          @exception_message ||= value.to_s
        elsif name == "exception.message"
          @exception_message = value.to_s
        elsif name == "exception.stacktrace"
          @exception_stacktrace = value.to_s
        end
      end
    end
  end
end
