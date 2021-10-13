import Config

config :opentelemetry_ecto,
  ecto_repos: [OpentelemetryEcto.TestRepo]

config :opentelemetry_ecto, OpentelemetryEcto.TestRepo,
  hostname: "localhost",
  username: "postgres",
  database: "opentelemetry_ecto_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :opentelemetry,
  sampler: {:otel_sampler_always_on, %{}},
  tracer: :otel_tracer_default,
  processors: [{:otel_batch_processor, %{scheduled_delay_ms: 1}}]
