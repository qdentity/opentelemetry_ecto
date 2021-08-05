defmodule OpentelemetryEcto do
  @moduledoc """
  Telemetry handler for creating OpenTelemetry Spans from Ecto query events.
  """

  require OpenTelemetry.Tracer

  @type setup_opts :: [time_unit() | sampler() | span_prefix()]

  @type time_unit :: {:time_unit, System.time_unit()}
  @type sampler :: {:sampler, :otel_sampler.t() | sampler_fun() | nil}
  @type span_prefix :: {:span_prefix, String.t()}

  @type sampler_fun :: (telemetry_data() -> :otel_sampler.t() | nil)
  @type telemetry_data :: %{measurements: map(), meta: map()}

  @doc """
  Attaches the OpentelemetryEcto handler to your repo events. This should be called
  from your application behaviour on startup.

  Example:

      OpentelemetryEcto.setup([:blog, :repo])

  You may also supply the following options in the second argument:

    * `:time_unit` - a time unit used to convert the values of query phase
      timings, defaults to `:microsecond`. See `System.convert_time_unit/3`.

    * `:sampler` - an optional sampler or sampler function to use when creating
       spans. The function accepts the Ecto Telemetry measurements and metadata
       and decides whether to use a sampler or not.

    * `:span_prefix` - the first part of the span name, as a `String.t`,
      defaults to the concatenation of the event name with periods, e.g.
      `"blog.repo.query"`. This will always be followed with a colon and the
      source (the table name for SQL adapters).
  """
  @spec setup(String.t(), setup_opts()) :: :ok | {:error, :already_exists}
  def setup(event_prefix, config \\ []) do
    # register the tracer. just re-registers if called for multiple repos
    _ = OpenTelemetry.register_application_tracer(:opentelemetry_ecto)

    event = event_prefix ++ [:query]
    :telemetry.attach({__MODULE__, event}, event, &__MODULE__.handle_event/4, config)
  end

  @doc false
  def handle_event(
        event,
        measurements,
        %{query: query, source: source, result: query_result, repo: repo, type: type} = meta,
        config
      ) do
    # Doing all this even if the span isn't sampled so the sampler
    # could technically use the attributes to decide if it should sample or not
    # (using the `sampler` option)

    total_time = measurements.total_time
    end_time = :opentelemetry.timestamp()
    start_time = end_time - total_time
    database = repo.config()[:database]

    url =
      case repo.config()[:url] do
        nil ->
          # TODO: add port
          URI.to_string(%URI{scheme: "ecto", host: repo.config()[:hostname]})

        url ->
          url
      end

    span_name =
      case Keyword.fetch(config, :span_prefix) do
        {:ok, prefix} -> prefix
        :error -> Enum.join(event, ".")
      end <> ":#{source}"

    time_unit = Keyword.get(config, :time_unit, :microsecond)

    db_type =
      case type do
        :ecto_sql_query -> :sql
        _ -> type
      end

    result =
      case query_result do
        {:ok, _} -> []
        _ -> [error: true]
      end

    # TODO: need connection information to complete the required attributes
    # net.peer.name or net.peer.ip and net.peer.port
    base_attributes =
      Keyword.merge(result,
        "db.type": db_type,
        "db.statement": query,
        source: source,
        "db.instance": database,
        "db.url": url,
        "total_time_#{time_unit}s": System.convert_time_unit(total_time, :native, time_unit)
      )

    attributes =
      measurements
      |> Enum.into(%{})
      |> Map.take(~w(decode_time query_time queue_time)a)
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Enum.map(fn {k, v} ->
        {String.to_atom("#{k}_#{time_unit}s"), System.convert_time_unit(v, :native, time_unit)}
      end)

    parent_context_attached = maybe_attach_parent_context()

    sampler = get_sampler(config[:sampler], %{measurements: measurements, meta: meta})

    opts =
      %{start_time: start_time, attributes: attributes ++ base_attributes}
      |> maybe_put_sampler(sampler)

    OpenTelemetry.Tracer.start_span(span_name, opts)
    |> OpenTelemetry.Span.end_span()

    if parent_context_attached do
      OpenTelemetry.Ctx.clear()
    end
  end

  defp maybe_attach_parent_context do
    with :ok <- with_no_context_set?(),
         {:ok, parent_pid} <- with_parent_pid(),
         {:ok, parent_context} <- with_parent_otel_context(parent_pid) do
      OpenTelemetry.Ctx.attach(parent_context)
      true
    end
  end

  defp with_no_context_set? do
    if OpenTelemetry.Ctx.get_current() |> map_size() == 0 do
      :ok
    else
      false
    end
  end

  defp with_parent_pid do
    case Process.get(:"$callers") do
      [parent_pid | _] when is_pid(parent_pid) -> {:ok, parent_pid}
      _ -> false
    end
  end

  defp with_parent_otel_context(parent_pid) do
    parent_ctx = Process.info(parent_pid) |> Keyword.get(:dictionary) |> Keyword.get(:"$__current_otel_ctx")

    if is_map(parent_ctx) and map_size(parent_ctx) > 0 do
      {:ok, parent_ctx}
    else
      false
    end
  end

  defp get_sampler(sampler_fun, telemetry_data) when is_function(sampler_fun) do
    sampler_fun.(telemetry_data)
  end

  defp get_sampler(sampler, _telemetry_data), do: sampler

  defp maybe_put_sampler(opts, sampler) do
    if sampler == nil do
      opts
    else
      Map.put(opts, :sampler, sampler)
    end
  end
end
