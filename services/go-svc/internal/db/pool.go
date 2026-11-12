// Package db wires the pgx connection pool with the otelpgx tracer.
// The tracer emits spans under the InstrumentationScope name
// `github.com/exaring/otelpgx`: this is the marker perf-sentinel's
// strict classifier needs to surface as the ORM-equivalent signal for
// the pgx bare-driver path (Gap #20 candidate stack).
package db

import (
	"context"
	"fmt"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
)

// New parses the connection string, attaches the otelpgx tracer, and
// returns a connected pool. Pool capped at 10 to make pool-saturation
// observable at concurrency=20.
func New(ctx context.Context, connString string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.MaxConns < 1 || cfg.MaxConns > 10 {
		cfg.MaxConns = 10
	}
	cfg.ConnConfig.Tracer = otelpgx.NewTracer(
		otelpgx.WithIncludeQueryParameters(),
		// otelpgx 0.13 defaults to bare "SELECT" span names; keep the
		// pre-0.13 "query <full SQL>" names the lab findings were baselined on.
		otelpgx.WithFullSQLInSpanName(),
		otelpgx.WithQuerySpanNamePrefix(),
	)
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("new pool: %w", err)
	}
	return pool, nil
}
