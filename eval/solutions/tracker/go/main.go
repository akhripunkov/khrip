package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The statements run as one implicit transaction, so the advisory lock
// keeps servers starting at the same time from racing on the DDL.
const schema = `
SELECT pg_advisory_xact_lock(4208);
CREATE TABLE IF NOT EXISTS users (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	email text NOT NULL UNIQUE,
	name text NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
	key text PRIMARY KEY,
	name text NOT NULL,
	owner_id bigint NOT NULL REFERENCES users,
	last_number integer NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS issues (
	key text GENERATED ALWAYS AS (project || '-' || number) STORED PRIMARY KEY,
	project text NOT NULL REFERENCES projects,
	number integer NOT NULL,
	title text NOT NULL,
	status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'done')),
	priority text NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
	assignee_id bigint REFERENCES users,
	created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
	UNIQUE (project, number)
);
`

const issueColumns = "key, project, number, title, status, priority, assignee_id, created_at, updated_at"

type User struct {
	ID    int64  `json:"id"`
	Email string `json:"email"`
	Name  string `json:"name"`
}

type Project struct {
	Key     string `json:"key"`
	Name    string `json:"name"`
	OwnerID int64  `json:"owner_id"`
}

type Issue struct {
	Key        string `json:"key"`
	Project    string `json:"project"`
	Number     int    `json:"number"`
	Title      string `json:"title"`
	Status     string `json:"status"`
	Priority   string `json:"priority"`
	AssigneeID *int64 `json:"assignee_id"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

type Assignee struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Active int    `json:"active"`
}

type Summary struct {
	Total      int        `json:"total"`
	Open       int        `json:"open"`
	InProgress int        `json:"in_progress"`
	Done       int        `json:"done"`
	Assignees  []Assignee `json:"assignees"`
}

// optional tells a field sent as null apart from a field that was not sent.
type optional[T any] struct {
	set   bool
	value *T
}

func (o *optional[T]) UnmarshalJSON(data []byte) error {
	o.set = true
	return json.Unmarshal(data, &o.value)
}

var (
	db         *pgxpool.Pool
	emailRegex = regexp.MustCompile(`^[^@\s\pZ]+@[^@\s\pZ]+$`)
	keyRegex   = regexp.MustCompile(`^[A-Z]{2,5}$`)
	statuses   = map[string]bool{"open": true, "in_progress": true, "done": true}
	priorities = map[string]bool{"low": true, "medium": true, "high": true}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// Duplicates and unknown references are left to the unique and foreign key
// constraints, which check them atomically with the write.
func writeError(w http.ResponseWriter, err error) {
	var pe *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.Error(w, "not found", http.StatusNotFound)
	case errors.As(err, &pe) && pe.Code == "23505":
		http.Error(w, "already exists", http.StatusConflict)
	case errors.As(err, &pe) && pe.Code == "23503":
		http.Error(w, "user not found", http.StatusNotFound)
	default:
		log.Print(err)
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}

func validTitle(s string) bool {
	return strings.TrimSpace(s) != "" && utf8.RuneCountInString(s) <= 200
}

func scanIssue(row pgx.CollectableRow) (Issue, error) {
	var i Issue
	var created, updated time.Time
	err := row.Scan(&i.Key, &i.Project, &i.Number, &i.Title, &i.Status, &i.Priority, &i.AssigneeID, &created, &updated)
	i.CreatedAt = created.UTC().Format(time.RFC3339)
	i.UpdatedAt = updated.UTC().Format(time.RFC3339)
	return i, err
}

func respondIssue(w http.ResponseWriter, r *http.Request, status int, sql string, args ...any) {
	rows, _ := db.Query(r.Context(), sql, args...)
	issue, err := pgx.CollectOneRow(rows, scanIssue)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, status, issue)
}

func createUser(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Name  string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !emailRegex.MatchString(req.Email) || strings.TrimSpace(req.Name) == "" {
		http.Error(w, "email must be name@domain without spaces; name is required", http.StatusBadRequest)
		return
	}
	u := User{Email: strings.ToLower(req.Email), Name: req.Name}
	if err := db.QueryRow(r.Context(), "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id", u.Email, u.Name).Scan(&u.ID); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, u)
}

func createProject(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Key     string `json:"key"`
		Name    string `json:"name"`
		OwnerID *int64 `json:"owner_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !keyRegex.MatchString(req.Key) || strings.TrimSpace(req.Name) == "" || req.OwnerID == nil {
		http.Error(w, "key must be 2-5 letters A-Z; name and owner_id are required", http.StatusBadRequest)
		return
	}
	p := Project{Key: req.Key, Name: req.Name, OwnerID: *req.OwnerID}
	if _, err := db.Exec(r.Context(), "INSERT INTO projects (key, name, owner_id) VALUES ($1, $2, $3)", p.Key, p.Name, p.OwnerID); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, p)
}

// The UPDATE locks the project row, so concurrent creates take numbers one
// after another; a failed insert rolls the counter back, leaving no gaps.
func createIssue(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title      string `json:"title"`
		Priority   string `json:"priority"`
		AssigneeID *int64 `json:"assignee_id"`
	}
	req.Priority = "medium"
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !validTitle(req.Title) || !priorities[req.Priority] {
		http.Error(w, "title must be 1-200 characters; priority must be low, medium or high", http.StatusBadRequest)
		return
	}
	respondIssue(w, r, http.StatusCreated, `
		WITH project AS (
			UPDATE projects SET last_number = last_number + 1 WHERE key = $1 RETURNING key, last_number
		)
		INSERT INTO issues (project, number, title, priority, assignee_id)
		SELECT key, last_number, $2, $3, $4 FROM project
		RETURNING `+issueColumns,
		r.PathValue("key"), req.Title, req.Priority, req.AssigneeID)
}

func getIssue(w http.ResponseWriter, r *http.Request) {
	respondIssue(w, r, http.StatusOK, "SELECT "+issueColumns+" FROM issues WHERE key = $1", r.PathValue("key"))
}

func updateIssue(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title      optional[string] `json:"title"`
		Status     optional[string] `json:"status"`
		Priority   optional[string] `json:"priority"`
		AssigneeID optional[int64]  `json:"assignee_id"`
	}
	err := json.NewDecoder(r.Body).Decode(&req)
	t, s, p := req.Title, req.Status, req.Priority
	if err != nil || t.set && (t.value == nil || !validTitle(*t.value)) ||
		s.set && (s.value == nil || !statuses[*s.value]) || p.set && (p.value == nil || !priorities[*p.value]) {
		http.Error(w, "title must be 1-200 characters; status must be open, in_progress or done; priority must be low, medium or high", http.StatusBadRequest)
		return
	}
	respondIssue(w, r, http.StatusOK, `
		UPDATE issues SET title = coalesce($2, title), status = coalesce($3, status), priority = coalesce($4, priority),
			assignee_id = CASE WHEN $5 THEN $6 ELSE assignee_id END, updated_at = now()
		WHERE key = $1
		RETURNING `+issueColumns,
		r.PathValue("key"), t.value, s.value, p.value, req.AssigneeID.set, req.AssigneeID.value)
}

func deleteIssue(w http.ResponseWriter, r *http.Request) {
	tag, err := db.Exec(r.Context(), "DELETE FROM issues WHERE key = $1", r.PathValue("key"))
	if err != nil {
		writeError(w, err)
		return
	}
	if tag.RowsAffected() == 0 {
		http.Error(w, "issue not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func listIssues(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var status *string
	if q.Has("status") {
		s := q.Get("status")
		if !statuses[s] {
			http.Error(w, "status must be open, in_progress or done", http.StatusBadRequest)
			return
		}
		status = &s
	}
	var assignee *int64
	unassigned := q.Get("assignee_id") == "none"
	if q.Has("assignee_id") && !unassigned {
		id, err := strconv.ParseInt(q.Get("assignee_id"), 10, 64)
		if err != nil {
			http.Error(w, "assignee_id must be a user id or none", http.StatusBadRequest)
			return
		}
		assignee = &id
	}
	ctx, key := r.Context(), r.PathValue("key")
	if err := db.QueryRow(ctx, "SELECT 1 FROM projects WHERE key = $1", key).Scan(new(int)); err != nil {
		writeError(w, err)
		return
	}
	rows, _ := db.Query(ctx, "SELECT "+issueColumns+` FROM issues
		WHERE project = $1 AND ($2::text IS NULL OR status = $2)
			AND ($3::bigint IS NULL OR assignee_id = $3) AND (NOT $4 OR assignee_id IS NULL)
			AND strpos(lower(title), lower($5)) > 0
		ORDER BY number`, key, status, assignee, unassigned, q.Get("q"))
	list, err := pgx.CollectRows(rows, scanIssue)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// Both queries read one snapshot, so the counts and the assignees agree.
func summary(w http.ResponseWriter, r *http.Request) {
	ctx, key := r.Context(), r.PathValue("key")
	var s Summary
	err := pgx.BeginTxFunc(ctx, db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT count(i.key), count(*) FILTER (WHERE i.status = 'open'),
				count(*) FILTER (WHERE i.status = 'in_progress'), count(*) FILTER (WHERE i.status = 'done')
			FROM projects p LEFT JOIN issues i ON i.project = p.key
			WHERE p.key = $1
			GROUP BY p.key`, key).Scan(&s.Total, &s.Open, &s.InProgress, &s.Done)
		if err != nil {
			return err
		}
		rows, _ := tx.Query(ctx, `
			SELECT u.id, u.name, count(*) AS active
			FROM issues i JOIN users u ON u.id = i.assignee_id
			WHERE i.project = $1 AND i.status <> 'done'
			GROUP BY u.id
			ORDER BY active DESC, u.id`, key)
		s.Assignees, err = pgx.CollectRows(rows, pgx.RowToStructByName[Assignee])
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, s)
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
	http.HandleFunc("POST /users", createUser)
	http.HandleFunc("POST /projects", createProject)
	http.HandleFunc("POST /projects/{key}/issues", createIssue)
	http.HandleFunc("GET /projects/{key}/issues", listIssues)
	http.HandleFunc("GET /projects/{key}/summary", summary)
	http.HandleFunc("GET /issues/{key}", getIssue)
	http.HandleFunc("PATCH /issues/{key}", updateIssue)
	http.HandleFunc("DELETE /issues/{key}", deleteIssue)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
