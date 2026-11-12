// go-svc: Go 1.27 multistack member for perf-sentinel-simulation-lab.
// chi router wrapped by otelhttp, pgx pool wrapped by otelpgx.
//
// Env overrides:
//
//	HTTP_PORT: overrides the default port 8093.
//	SELF_BASE_URL: overrides the self-loop base URL.
//	DB_DSN: Postgres connection string (Postgres URL or
//	                 key=value form parseable by pgxpool).
//	OTEL_*: standard OTel env vars consumed by the SDK.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/perf-sentinel/lab/go-svc/internal/db"
	"github.com/perf-sentinel/lab/go-svc/internal/messaging"
	otelinit "github.com/perf-sentinel/lab/go-svc/internal/otel"
	"github.com/perf-sentinel/lab/go-svc/internal/web"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const defaultPort = 8093

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	port := envOrInt("HTTP_PORT", defaultPort)
	selfBase := envOr("SELF_BASE_URL", fmt.Sprintf("http://localhost:%d", port))
	dsn := envOr("DB_DSN", "postgres://go_user:lab_go@postgres.db.svc.cluster.local:5432/lab?search_path=%22go%22&pool_max_conns=10")
	serviceName := envOr("OTEL_SERVICE_NAME", "go-svc")

	shutdownTracer, err := otelinit.Init(ctx, serviceName)
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownTracer(shutdownCtx)
	}()

	pool, err := db.New(ctx, dsn)
	if err != nil {
		log.Fatalf("pgx pool: %v", err)
	}
	defer pool.Close()

	if err := db.EnsureSchema(ctx, pool); err != nil {
		log.Fatalf("schema bootstrap: %v", err)
	}

	// otelhttp.NewTransport wraps the stdlib RoundTripper so outbound
	// calls emit CLIENT spans under scope
	// `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`.
	httpClient := &http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   15 * time.Second,
	}

	publisher, err := messaging.NewFromEnv()
	if err != nil {
		log.Fatalf("messaging config: %v", err)
	}
	handler := web.Mount(pool, httpClient, selfBase, publisher)
	// otelhttp.NewHandler wraps the chi router so SERVER spans carry
	// the http.route attribute. Inner middleware (otelhttp) sees the
	// chi route template via the RouteTag pattern below.
	rootHandler := otelhttp.NewHandler(handler, "go-svc")

	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", port),
		Handler:           rootHandler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("go-svc listening on :%d (selfBase=%s)", port, selfBase)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutdown signal received")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("server shutdown: %v", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envOrInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(v)
	if err != nil {
		log.Fatalf("invalid integer for env %s: %q", key, v)
	}
	return parsed
}
