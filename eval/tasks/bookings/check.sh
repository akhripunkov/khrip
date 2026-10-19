#!/usr/bin/env bash
# Проверка бронирования переговорных; сервер уже запущен.
. "$(dirname "$0")/../../lib.sh"

book() {
	check "$1" "$2" "$3" "${J[@]}" -X POST $U/bookings -d "$4"
}
check "room" 201 '"id":1 && "name":"Blue" && "capacity":6' "${J[@]}" -X POST $U/rooms -d '{"name":"Blue","capacity":6}'
check "room 2" 201 '"id":2' "${J[@]}" -X POST $U/rooms -d '{"name":"Red","capacity":2}'
check "blank room" 400 '' "${J[@]}" -X POST $U/rooms -d '{"name":"","capacity":2}'
check "zero capacity" 400 '' "${J[@]}" -X POST $U/rooms -d '{"name":"Tiny","capacity":0}'
book "book" 201 '"id":1 && "room_id":1 && "title":"Standup" && "start":"2026-10-19T09:00:00Z" && "end":"2026-10-19T09:30:00Z"' \
	'{"room_id":1,"title":"Standup","start":"2026-10-19T09:00:00Z","end":"2026-10-19T09:30:00Z"}'
book "touching" 201 '"id":2' '{"room_id":1,"title":"Review","start":"2026-10-19T09:30:00Z","end":"2026-10-19T11:00:00Z"}'
book "overlap" 409 '' '{"room_id":1,"title":"Clash","start":"2026-10-19T10:59:59Z","end":"2026-10-19T12:00:00Z"}'
book "inside" 409 '' '{"room_id":1,"title":"Clash","start":"2026-10-19T09:10:00Z","end":"2026-10-19T09:20:00Z"}'
book "around" 409 '' '{"room_id":1,"title":"Clash","start":"2026-10-19T08:00:00Z","end":"2026-10-19T12:00:00Z"}'
book "other room" 201 '"id":3 && "room_id":2' '{"room_id":2,"title":"1:1","start":"2026-10-19T09:00:00Z","end":"2026-10-19T09:30:00Z"}'
book "overnight" 201 '"id":4' '{"room_id":1,"title":"Night run","start":"2026-10-19T22:00:00Z","end":"2026-10-20T04:00:00Z"}'
book "next day" 201 '"id":5' '{"room_id":1,"title":"Planning","start":"2026-10-20T10:00:00Z","end":"2026-10-20T11:00:00Z"}'
book "earlier" 201 '"id":6' '{"room_id":1,"title":"Breakfast","start":"2026-10-19T07:00:00Z","end":"2026-10-19T08:00:00Z"}'
book "unknown room" 404 '' '{"room_id":9,"title":"x","start":"2026-10-21T10:00:00Z","end":"2026-10-21T11:00:00Z"}'
book "blank title" 400 '' '{"room_id":1,"title":" ","start":"2026-10-21T10:00:00Z","end":"2026-10-21T11:00:00Z"}'
book "end before start" 400 '' '{"room_id":1,"title":"x","start":"2026-10-21T11:00:00Z","end":"2026-10-21T10:00:00Z"}'
book "zero length" 400 '' '{"room_id":1,"title":"x","start":"2026-10-21T11:00:00Z","end":"2026-10-21T11:00:00Z"}'
book "too long" 400 '' '{"room_id":1,"title":"x","start":"2026-10-21T08:00:00Z","end":"2026-10-21T16:00:01Z"}'
book "eight hours" 201 '"id":7' '{"room_id":1,"title":"Workshop","start":"2026-10-21T08:00:00Z","end":"2026-10-21T16:00:00Z"}'
book "bad format" 400 '' '{"room_id":1,"title":"x","start":"2026-10-22 10:00:00","end":"2026-10-22T11:00:00Z"}'
book "bad date" 400 '' '{"room_id":1,"title":"x","start":"2026-02-30T10:00:00Z","end":"2026-02-30T11:00:00Z"}'
book "bad hour" 400 '' '{"room_id":1,"title":"x","start":"2026-10-22T24:00:00Z","end":"2026-10-22T25:00:00Z"}'
book "leap day" 201 '"id":8' '{"room_id":2,"title":"Leap","start":"2028-02-29T10:00:00Z","end":"2028-02-29T11:00:00Z"}'
book "across month" 201 '"id":9' '{"room_id":2,"title":"Late","start":"2026-10-31T20:00:00Z","end":"2026-11-01T02:00:00Z"}'
check "list" 200 '' $U/rooms/1/bookings
jtest "list sorted" "[b['id'] for b in j] == [6, 1, 2, 4, 5, 7]"
check "list day" 200 '' "$U/rooms/1/bookings?date=2026-10-20"
jtest "day overlap" "[b['id'] for b in j] == [4, 5]"
check "list day 2" 200 '' "$U/rooms/2/bookings?date=2026-11-01"
jtest "day across month" "[b['id'] for b in j] == [9]"
check "bad day" 400 '' "$U/rooms/1/bookings?date=19.10.2026"
check "list unknown" 404 '' $U/rooms/9/bookings
check "delete" 204 '' -X DELETE $U/bookings/2
check "delete again" 404 '' -X DELETE $U/bookings/2
book "freed" 201 '"id":10' '{"room_id":1,"title":"Moved","start":"2026-10-19T10:00:00Z","end":"2026-10-19T10:45:00Z"}'
finish
