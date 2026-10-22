// Разбор больших результатов в pgx: те же запросы, лучшее из пяти, мс.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

type R struct {
	ID   int64  `db:"id"`
	Name string `db:"name"`
	Note string `db:"note"`
}

func main() {
	ctx := context.Background()
	c, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		panic(err)
	}
	ints, rows := time.Hour, time.Hour
	for i := 0; i < 5; i++ {
		t0 := time.Now()
		r1, _ := c.Query(ctx, "SELECT g FROM generate_series(1, 300000) g")
		xs, err := pgx.CollectRows(r1, pgx.RowTo[int64])
		t1 := time.Now()
		r2, _ := c.Query(ctx, "SELECT g AS id, 'name ' || g AS name, repeat('x', 100) AS note FROM generate_series(1, 100000) g")
		rs, err2 := pgx.CollectRows(r2, pgx.RowToStructByName[R])
		t2 := time.Now()
		if err != nil || err2 != nil || len(xs) != 300000 || len(rs) != 100000 {
			panic(fmt.Sprint(err, err2))
		}
		ints, rows = min(ints, t1.Sub(t0)), min(rows, t2.Sub(t1))
	}
	fmt.Printf("go\t%d\t%d\n", ints.Milliseconds(), rows.Milliseconds())
}
