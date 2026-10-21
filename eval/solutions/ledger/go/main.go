package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The statements run as one implicit transaction, so the advisory lock
// keeps servers starting at the same time from racing on the DDL.
const schema = `
SELECT pg_advisory_xact_lock(4207);
CREATE TABLE IF NOT EXISTS accounts (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	owner text NOT NULL,
	currency text NOT NULL,
	balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
);
CREATE TABLE IF NOT EXISTS transfers (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	from_id bigint NOT NULL REFERENCES accounts,
	to_id bigint NOT NULL REFERENCES accounts,
	amount bigint NOT NULL CHECK (amount > 0),
	created_at timestamptz NOT NULL DEFAULT now(),
	idempotency_key text UNIQUE
);
CREATE INDEX IF NOT EXISTS transfers_from_id ON transfers (from_id, id);
CREATE INDEX IF NOT EXISTS transfers_to_id ON transfers (to_id, id);
`

const (
	accountColumns  = "id, owner, currency, balance"
	transferColumns = "id, from_id, to_id, amount, created_at"
)

type Account struct {
	ID       int64  `json:"id"`
	Owner    string `json:"owner"`
	Currency string `json:"currency"`
	Balance  int64  `json:"balance"`
}

type Transfer struct {
	ID        int64  `json:"id"`
	From      int64  `json:"from"`
	To        int64  `json:"to"`
	Amount    int64  `json:"amount"`
	CreatedAt string `json:"created_at"`
}

type httpError struct {
	status int
	msg    string
}

func (e httpError) Error() string { return e.msg }

var (
	db         *pgxpool.Pool
	currencies = map[string]bool{"USD": true, "EUR": true, "GBP": true}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	var he httpError
	if errors.As(err, &he) {
		http.Error(w, he.msg, he.status)
		return
	}
	log.Print(err)
	http.Error(w, "internal error", http.StatusInternalServerError)
}

func pathID(r *http.Request) int64 {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id
}

func scanTransfer(row pgx.Row) (Transfer, error) {
	var t Transfer
	var created time.Time
	err := row.Scan(&t.ID, &t.From, &t.To, &t.Amount, &created)
	t.CreatedAt = created.UTC().Format(time.RFC3339)
	return t, err
}

func respondAccount(w http.ResponseWriter, r *http.Request, status int, sql string, args ...any) {
	var a Account
	err := db.QueryRow(r.Context(), sql, args...).Scan(&a.ID, &a.Owner, &a.Currency, &a.Balance)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.Error(w, "account not found", http.StatusNotFound)
	case err != nil:
		writeError(w, err)
	default:
		writeJSON(w, status, a)
	}
}

func createAccount(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Owner    string `json:"owner"`
		Currency string `json:"currency"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Owner) == "" || !currencies[req.Currency] {
		http.Error(w, "owner is required; currency must be USD, EUR or GBP", http.StatusBadRequest)
		return
	}
	respondAccount(w, r, http.StatusCreated,
		"INSERT INTO accounts (owner, currency) VALUES ($1, $2) RETURNING "+accountColumns, req.Owner, req.Currency)
}

func getAccount(w http.ResponseWriter, r *http.Request) {
	respondAccount(w, r, http.StatusOK, "SELECT "+accountColumns+" FROM accounts WHERE id = $1", pathID(r))
}

func deposit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Amount int64 `json:"amount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Amount <= 0 {
		http.Error(w, "amount must be positive", http.StatusBadRequest)
		return
	}
	respondAccount(w, r, http.StatusOK,
		"UPDATE accounts SET balance = balance + $2 WHERE id = $1 RETURNING "+accountColumns, pathID(r), req.Amount)
}

// Same-key requests are serialized by an advisory lock on the key; the two
// accounts are locked in id order, so crossing transfers cannot deadlock.
func transfer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		From   int64 `json:"from"`
		To     int64 `json:"to"`
		Amount int64 `json:"amount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Amount <= 0 || req.From == req.To {
		http.Error(w, "amount must be positive and accounts different", http.StatusBadRequest)
		return
	}
	var key *string
	if v := r.Header.Values("Idempotency-Key"); len(v) > 0 {
		if n := utf8.RuneCountInString(v[0]); n < 1 || n > 64 {
			http.Error(w, "Idempotency-Key must be 1-64 characters", http.StatusBadRequest)
			return
		}
		key = &v[0]
	}
	ctx := r.Context()
	var t Transfer
	err := pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		if key != nil {
			if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", *key); err != nil {
				return err
			}
			var err error
			t, err = scanTransfer(tx.QueryRow(ctx, "SELECT "+transferColumns+" FROM transfers WHERE idempotency_key = $1", *key))
			if err == nil {
				if t.From != req.From || t.To != req.To || t.Amount != req.Amount {
					return httpError{http.StatusUnprocessableEntity, "Idempotency-Key was used with a different request"}
				}
				return nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		rows, _ := tx.Query(ctx, "SELECT "+accountColumns+" FROM accounts WHERE id IN ($1, $2) ORDER BY id FOR UPDATE", req.From, req.To)
		accounts, err := pgx.CollectRows(rows, pgx.RowToStructByName[Account])
		if err != nil {
			return err
		}
		if len(accounts) < 2 {
			return httpError{http.StatusNotFound, "account not found"}
		}
		from, to := accounts[0], accounts[1]
		if from.ID != req.From {
			from, to = to, from
		}
		if from.Currency != to.Currency {
			return httpError{http.StatusUnprocessableEntity, "accounts have different currencies"}
		}
		if from.Balance < req.Amount {
			return httpError{http.StatusConflict, "insufficient funds"}
		}
		if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance - $2 WHERE id = $1", req.From, req.Amount); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "UPDATE accounts SET balance = balance + $2 WHERE id = $1", req.To, req.Amount); err != nil {
			return err
		}
		t, err = scanTransfer(tx.QueryRow(ctx,
			"INSERT INTO transfers (from_id, to_id, amount, idempotency_key) VALUES ($1, $2, $3, $4) RETURNING "+transferColumns,
			req.From, req.To, req.Amount, key))
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, t)
}

func listTransfers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit := 20
	if q.Has("limit") {
		n, err := strconv.Atoi(q.Get("limit"))
		if err != nil || n < 1 || n > 100 {
			http.Error(w, "limit must be 1-100", http.StatusBadRequest)
			return
		}
		limit = n
	}
	before := int64(math.MaxInt64)
	if q.Has("before") {
		n, err := strconv.ParseInt(q.Get("before"), 10, 64)
		if err != nil {
			http.Error(w, "before must be a transfer id", http.StatusBadRequest)
			return
		}
		before = n
	}
	ctx, id := r.Context(), pathID(r)
	var exists bool
	if err := db.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)", id).Scan(&exists); err != nil {
		writeError(w, err)
		return
	}
	if !exists {
		http.Error(w, "account not found", http.StatusNotFound)
		return
	}
	rows, _ := db.Query(ctx, "SELECT "+transferColumns+" FROM transfers WHERE (from_id = $1 OR to_id = $1) AND id < $2 ORDER BY id DESC LIMIT $3",
		id, before, limit)
	list, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Transfer, error) { return scanTransfer(row) })
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func stats(w http.ResponseWriter, r *http.Request) {
	var accounts, transfers, usd, eur, gbp int64
	err := db.QueryRow(r.Context(), `
		SELECT count(*), (SELECT count(*) FROM transfers),
			coalesce(sum(balance) FILTER (WHERE currency = 'USD'), 0)::bigint,
			coalesce(sum(balance) FILTER (WHERE currency = 'EUR'), 0)::bigint,
			coalesce(sum(balance) FILTER (WHERE currency = 'GBP'), 0)::bigint
		FROM accounts`).Scan(&accounts, &transfers, &usd, &eur, &gbp)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accounts":  accounts,
		"transfers": transfers,
		"balances":  map[string]int64{"USD": usd, "EUR": eur, "GBP": gbp},
	})
}

func main() {
	ctx := context.Background()
	var err error
	if db, err = pgxpool.New(ctx, os.Getenv("DATABASE_URL")); err != nil {
		log.Fatal(err)
	}
	if _, err := db.Exec(ctx, schema); err != nil {
		log.Fatal(err)
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	http.HandleFunc("POST /accounts", createAccount)
	http.HandleFunc("GET /accounts/{id}", getAccount)
	http.HandleFunc("POST /accounts/{id}/deposit", deposit)
	http.HandleFunc("POST /transfers", transfer)
	http.HandleFunc("GET /accounts/{id}/transfers", listTransfers)
	http.HandleFunc("GET /stats", stats)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
