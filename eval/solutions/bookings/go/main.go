package main

import (
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Room struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Capacity int    `json:"capacity"`
}

type Booking struct {
	ID     int    `json:"id"`
	RoomID int    `json:"room_id"`
	Title  string `json:"title"`
	Start  string `json:"start"`
	End    string `json:"end"`
	start  time.Time
	end    time.Time
}

const layout = "2006-01-02T15:04:05Z"

var (
	mu          sync.Mutex
	rooms       []*Room
	bookings    = map[int]*Booking{}
	lastBooking = 0
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func createRoom(w http.ResponseWriter, r *http.Request) {
	var room Room
	if err := json.NewDecoder(r.Body).Decode(&room); err != nil || strings.TrimSpace(room.Name) == "" || room.Capacity < 1 {
		http.Error(w, "name is required and capacity must be at least 1", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	room.ID = len(rooms) + 1
	rooms = append(rooms, &room)
	writeJSON(w, http.StatusCreated, room)
}

func createBooking(w http.ResponseWriter, r *http.Request) {
	var b Booking
	err := json.NewDecoder(r.Body).Decode(&b)
	var err1, err2 error
	b.start, err1 = time.Parse(layout, b.Start)
	b.end, err2 = time.Parse(layout, b.End)
	if err != nil || err1 != nil || err2 != nil || !b.end.After(b.start) || b.end.Sub(b.start) > 8*time.Hour || strings.TrimSpace(b.Title) == "" {
		http.Error(w, "need a title and valid start < end, at most 8 hours apart", http.StatusBadRequest)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if b.RoomID < 1 || b.RoomID > len(rooms) {
		http.NotFound(w, r)
		return
	}
	for _, o := range bookings {
		if o.RoomID == b.RoomID && o.start.Before(b.end) && b.start.Before(o.end) {
			http.Error(w, "the room is booked at that time", http.StatusConflict)
			return
		}
	}
	lastBooking++
	b.ID = lastBooking
	bookings[b.ID] = &b
	writeJSON(w, http.StatusCreated, b)
}

func roomBookings(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(r.PathValue("id"))
	from, to := time.Time{}, time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC)
	if date := r.URL.Query().Get("date"); date != "" {
		day, err := time.Parse("2006-01-02", date)
		if err != nil {
			http.Error(w, "date must look like 2026-10-19", http.StatusBadRequest)
			return
		}
		from, to = day, day.Add(24*time.Hour)
	}
	mu.Lock()
	defer mu.Unlock()
	if id < 1 || id > len(rooms) {
		http.NotFound(w, r)
		return
	}
	list := []*Booking{}
	for _, b := range bookings {
		if b.RoomID == id && b.start.Before(to) && from.Before(b.end) {
			list = append(list, b)
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].start.Before(list[j].start) })
	writeJSON(w, http.StatusOK, list)
}

func deleteBooking(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(r.PathValue("id"))
	mu.Lock()
	defer mu.Unlock()
	if bookings[id] == nil {
		http.NotFound(w, r)
		return
	}
	delete(bookings, id)
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	http.HandleFunc("POST /rooms", createRoom)
	http.HandleFunc("POST /bookings", createBooking)
	http.HandleFunc("GET /rooms/{id}/bookings", roomBookings)
	http.HandleFunc("DELETE /bookings/{id}", deleteBooking)
	http.ListenAndServe(":8080", nil)
}
