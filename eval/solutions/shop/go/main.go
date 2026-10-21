package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"maps"
	"math"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The statements run as one implicit transaction, so the advisory lock
// keeps servers starting at the same time from racing on the DDL.
const schema = `
SELECT pg_advisory_xact_lock(4208);
CREATE TABLE IF NOT EXISTS categories (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	name text NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS categories_name ON categories (lower(name));
CREATE TABLE IF NOT EXISTS products (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	name text NOT NULL,
	category_id bigint NOT NULL REFERENCES categories,
	price bigint NOT NULL CHECK (price > 0),
	stock bigint NOT NULL CHECK (stock >= 0),
	tags text[] NOT NULL
);
CREATE INDEX IF NOT EXISTS products_category_id ON products (category_id);
CREATE TABLE IF NOT EXISTS orders (
	id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	customer text NOT NULL,
	status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
	total bigint NOT NULL,
	created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_customer ON orders (customer, id);
CREATE TABLE IF NOT EXISTS order_lines (
	order_id bigint NOT NULL REFERENCES orders,
	line int NOT NULL,
	product_id bigint NOT NULL REFERENCES products,
	qty bigint NOT NULL CHECK (qty > 0),
	price bigint NOT NULL,
	PRIMARY KEY (order_id, line)
);
`

const (
	productColumns = "id, name, category_id, price, stock, tags"
	orderColumns   = `id, customer, status, total,
		to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at,
		(SELECT json_agg(json_build_object('product_id', product_id, 'qty', qty, 'price', price) ORDER BY line)
			FROM order_lines WHERE order_id = orders.id) AS lines`
)

type Category struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type Product struct {
	ID         int64    `json:"id"`
	Name       string   `json:"name"`
	CategoryID int64    `json:"category_id"`
	Price      int64    `json:"price"`
	Stock      int64    `json:"stock"`
	Tags       []string `json:"tags"`
}

type Line struct {
	ProductID int64 `json:"product_id"`
	Qty       int64 `json:"qty"`
	Price     int64 `json:"price"`
}

type Order struct {
	ID        int64  `json:"id"`
	Customer  string `json:"customer"`
	Status    string `json:"status"`
	Total     int64  `json:"total"`
	CreatedAt string `json:"created_at"`
	Lines     []Line `json:"lines"`
}

type CategoryStats struct {
	Category  string `json:"category"`
	Products  int64  `json:"products"`
	UnitsSold int64  `json:"units_sold"`
	Revenue   int64  `json:"revenue"`
}

// productInput holds a product body; a nil field was not given.
type productInput struct {
	Name       *string  `json:"name"`
	CategoryID *int64   `json:"category_id"`
	Price      *int64   `json:"price"`
	Stock      *int64   `json:"stock"`
	Tags       []string `json:"tags"`
}

const productRules = "name must not be blank, price > 0, stock >= 0, at most 5 tags of 1-20 lower-case letters or digits"

type httpError struct {
	status int
	msg    string
}

func (e httpError) Error() string { return e.msg }

var (
	db         *pgxpool.Pool
	tagPattern = regexp.MustCompile(`^[a-z0-9]{1,20}$`)
	sortOrders = map[string]string{"": "id", "price": "price, id", "-price": "price DESC, id", "name": "name, id"}
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

// respondRow answers with the single row the query returns, or with missing when it returns none.
func respondRow[T any](w http.ResponseWriter, r *http.Request, status int, missing httpError, sql string, args ...any) {
	rows, _ := db.Query(r.Context(), sql, args...)
	v, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[T])
	if errors.Is(err, pgx.ErrNoRows) {
		err = missing
	}
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, status, v)
}

func respondList[T any](w http.ResponseWriter, r *http.Request, sql string, args ...any) {
	rows, _ := db.Query(r.Context(), sql, args...)
	list, err := pgx.CollectRows(rows, pgx.RowToStructByName[T])
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

func createCategory(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	err := json.NewDecoder(r.Body).Decode(&req)
	name := strings.TrimSpace(req.Name)
	if n := utf8.RuneCountInString(name); err != nil || n < 1 || n > 50 {
		http.Error(w, "name must be 1-50 characters", http.StatusBadRequest)
		return
	}
	respondRow[Category](w, r, http.StatusCreated, httpError{http.StatusConflict, "category already exists"},
		"INSERT INTO categories (name) VALUES ($1) ON CONFLICT DO NOTHING RETURNING id, name", name)
}

func listCategories(w http.ResponseWriter, r *http.Request) {
	respondList[Category](w, r, "SELECT id, name FROM categories ORDER BY name, id")
}

// validate checks the given fields and drops repeated tags.
func (p *productInput) validate() bool {
	if p.Name != nil && strings.TrimSpace(*p.Name) == "" || p.Price != nil && *p.Price <= 0 ||
		p.Stock != nil && *p.Stock < 0 || len(p.Tags) > 5 {
		return false
	}
	if p.Tags != nil {
		tags := []string{}
		for _, t := range p.Tags {
			if !tagPattern.MatchString(t) {
				return false
			}
			if !slices.Contains(tags, t) {
				tags = append(tags, t)
			}
		}
		p.Tags = tags
	}
	return true
}

func createProduct(w http.ResponseWriter, r *http.Request) {
	var p productInput
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil || p.Name == nil || p.CategoryID == nil ||
		p.Price == nil || p.Stock == nil || !p.validate() {
		http.Error(w, "category_id is required; "+productRules, http.StatusBadRequest)
		return
	}
	if p.Tags == nil {
		p.Tags = []string{}
	}
	respondRow[Product](w, r, http.StatusCreated, httpError{http.StatusNotFound, "category not found"},
		"INSERT INTO products (name, category_id, price, stock, tags) SELECT $1, id, $3, $4, $5 FROM categories WHERE id = $2 RETURNING "+productColumns,
		p.Name, p.CategoryID, p.Price, p.Stock, p.Tags)
}

func getProduct(w http.ResponseWriter, r *http.Request) {
	respondRow[Product](w, r, http.StatusOK, httpError{http.StatusNotFound, "product not found"},
		"SELECT "+productColumns+" FROM products WHERE id = $1", pathID(r))
}

func updateProduct(w http.ResponseWriter, r *http.Request) {
	var p productInput
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil || !p.validate() {
		http.Error(w, productRules, http.StatusBadRequest)
		return
	}
	respondRow[Product](w, r, http.StatusOK, httpError{http.StatusNotFound, "product not found"}, `
		UPDATE products SET name = coalesce($2, name), price = coalesce($3, price), stock = coalesce($4, stock), tags = coalesce($5, tags)
		WHERE id = $1 RETURNING `+productColumns,
		pathID(r), p.Name, p.Price, p.Stock, p.Tags)
}

func listProducts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	where, args := []string{"TRUE"}, []any{}
	filter := func(cond string, arg any) {
		args = append(args, arg)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	for _, f := range [][2]string{{"category_id", "category_id = $%d"}, {"min_price", "price >= $%d"}, {"max_price", "price <= $%d"}} {
		if q.Has(f[0]) {
			n, err := strconv.ParseInt(q.Get(f[0]), 10, 64)
			if err != nil {
				http.Error(w, f[0]+" must be an integer", http.StatusBadRequest)
				return
			}
			filter(f[1], n)
		}
	}
	if q.Has("tag") {
		filter("$%d = ANY (tags)", q.Get("tag"))
	}
	if q.Has("q") {
		filter("strpos(lower(name), lower($%d)) > 0", q.Get("q"))
	}
	switch q.Get("in_stock") {
	case "true":
		where = append(where, "stock > 0")
	case "", "false":
	default:
		http.Error(w, "in_stock must be true or false", http.StatusBadRequest)
		return
	}
	orderBy, ok := sortOrders[q.Get("sort")]
	if !ok {
		http.Error(w, "sort must be price, -price or name", http.StatusBadRequest)
		return
	}
	page, err := strconv.ParseInt(cmp.Or(q.Get("page"), "1"), 10, 32)
	if err != nil || page < 1 {
		http.Error(w, "page must be a positive integer", http.StatusBadRequest)
		return
	}
	perPage, err := strconv.ParseInt(cmp.Or(q.Get("per_page"), "10"), 10, 64)
	if err != nil || perPage < 1 || perPage > 50 {
		http.Error(w, "per_page must be 1-50", http.StatusBadRequest)
		return
	}

	cond := strings.Join(where, " AND ")
	var res struct {
		Items []Product `json:"items"`
		Total int64     `json:"total"`
	}
	ctx := r.Context()
	// One snapshot for both queries, so total agrees with the page.
	err = pgx.BeginTxFunc(ctx, db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM products WHERE "+cond, args...).Scan(&res.Total); err != nil {
			return err
		}
		rows, _ := tx.Query(ctx, fmt.Sprintf("SELECT %s FROM products WHERE %s ORDER BY %s LIMIT $%d OFFSET $%d",
			productColumns, cond, orderBy, len(args)+1, len(args)+2), append(args, perPage, (page-1)*perPage)...)
		var err error
		res.Items, err = pgx.CollectRows(rows, pgx.RowToStructByName[Product])
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func validEmail(s string) bool {
	local, domain, ok := strings.Cut(s, "@")
	return ok && local != "" && domain != "" && !strings.Contains(domain, "@") && !strings.ContainsFunc(s, unicode.IsSpace)
}

func placeOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Customer string `json:"customer"`
		Lines    []Line `json:"lines"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !validEmail(req.Customer) || len(req.Lines) == 0 {
		http.Error(w, "customer must be an email and lines must not be empty", http.StatusBadRequest)
		return
	}
	var lines []Line
	pos := map[int64]int{}
	for _, l := range req.Lines {
		i, seen := pos[l.ProductID]
		if l.Qty <= 0 || seen && l.Qty > math.MaxInt64-lines[i].Qty {
			http.Error(w, "qty must be positive and fit in 64 bits when merged", http.StatusBadRequest)
			return
		}
		if seen {
			lines[i].Qty += l.Qty
		} else {
			pos[l.ProductID] = len(lines)
			lines = append(lines, Line{ProductID: l.ProductID, Qty: l.Qty})
		}
	}

	ctx := r.Context()
	var o Order
	err := pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		// Products are locked in id order, here and in cancelOrder, so concurrent transactions cannot deadlock.
		rows, _ := tx.Query(ctx, "SELECT id, price, stock FROM products WHERE id = ANY ($1) ORDER BY id FOR UPDATE",
			slices.Collect(maps.Keys(pos)))
		stock := map[int64]int64{}
		var id, price, n int64
		_, err := pgx.ForEachRow(rows, []any{&id, &price, &n}, func() error {
			lines[pos[id]].Price = price
			stock[id] = n
			return nil
		})
		if err != nil {
			return err
		}
		if len(stock) < len(lines) {
			return httpError{http.StatusNotFound, "product not found"}
		}
		var total int64
		for _, l := range lines {
			if stock[l.ProductID] < l.Qty {
				return httpError{http.StatusConflict, fmt.Sprintf("not enough stock for product %d", l.ProductID)}
			}
			total += l.Qty * l.Price
		}
		var orderID int64
		err = tx.QueryRow(ctx, "INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING id",
			strings.ToLower(req.Customer), total).Scan(&orderID)
		if err != nil {
			return err
		}
		batch := &pgx.Batch{}
		for i, l := range lines {
			batch.Queue("UPDATE products SET stock = stock - $2 WHERE id = $1", l.ProductID, l.Qty)
			batch.Queue("INSERT INTO order_lines (order_id, line, product_id, qty, price) VALUES ($1, $2, $3, $4, $5)",
				orderID, i, l.ProductID, l.Qty, l.Price)
		}
		if err := tx.SendBatch(ctx, batch).Close(); err != nil {
			return err
		}
		rows, _ = tx.Query(ctx, "SELECT "+orderColumns+" FROM orders WHERE id = $1", orderID)
		o, err = pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[Order])
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, o)
}

func cancelOrder(w http.ResponseWriter, r *http.Request) {
	ctx, id := r.Context(), pathID(r)
	var o Order
	err := pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		var status string
		err := tx.QueryRow(ctx, "SELECT status FROM orders WHERE id = $1 FOR UPDATE", id).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return httpError{http.StatusNotFound, "order not found"}
		}
		if err != nil {
			return err
		}
		if status == "cancelled" {
			return httpError{http.StatusConflict, "order is already cancelled"}
		}
		_, err = tx.Exec(ctx, "SELECT FROM products WHERE id IN (SELECT product_id FROM order_lines WHERE order_id = $1) ORDER BY id FOR UPDATE", id)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "UPDATE products p SET stock = p.stock + l.qty FROM order_lines l WHERE l.order_id = $1 AND p.id = l.product_id", id)
		if err != nil {
			return err
		}
		rows, _ := tx.Query(ctx, "UPDATE orders SET status = 'cancelled' WHERE id = $1 RETURNING "+orderColumns, id)
		o, err = pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[Order])
		return err
	})
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, o)
}

func customerOrders(w http.ResponseWriter, r *http.Request) {
	respondList[Order](w, r, "SELECT "+orderColumns+" FROM orders WHERE customer = $1 ORDER BY id DESC",
		strings.ToLower(r.PathValue("email")))
}

func categoryStats(w http.ResponseWriter, r *http.Request) {
	respondList[CategoryStats](w, r, `
		SELECT c.name AS category, count(p.id) AS products,
			coalesce(sum(s.units), 0)::bigint AS units_sold, coalesce(sum(s.revenue), 0)::bigint AS revenue
		FROM categories c
		LEFT JOIN products p ON p.category_id = c.id
		LEFT JOIN (
			SELECT l.product_id, sum(l.qty) AS units, sum(l.qty * l.price) AS revenue
			FROM order_lines l JOIN orders o ON o.id = l.order_id
			WHERE o.status = 'placed'
			GROUP BY l.product_id
		) s ON s.product_id = p.id
		GROUP BY c.id
		ORDER BY revenue DESC, c.name`)
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
	http.HandleFunc("POST /categories", createCategory)
	http.HandleFunc("GET /categories", listCategories)
	http.HandleFunc("POST /products", createProduct)
	http.HandleFunc("GET /products", listProducts)
	http.HandleFunc("GET /products/{id}", getProduct)
	http.HandleFunc("PATCH /products/{id}", updateProduct)
	http.HandleFunc("POST /orders", placeOrder)
	http.HandleFunc("POST /orders/{id}/cancel", cancelOrder)
	http.HandleFunc("GET /customers/{email}/orders", customerOrders)
	http.HandleFunc("GET /stats/categories", categoryStats)
	log.Fatal(http.ListenAndServe(":"+cmp.Or(os.Getenv("PORT"), "8080"), nil))
}
