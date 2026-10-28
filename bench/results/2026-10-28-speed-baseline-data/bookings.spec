# bookings — адреса из дизассемблера build/khc 1349342
# POST /bookings (__route_1): разбор времени, проверка комнаты, any по всем броням
range __route_1 0x400200 0x4003e5 обработчик: пролог, проверки, ответ
range __route_1 0x4003e5 0x40048f цикл any и лямбда
range __route_1 0x40048f 0x400590 обработчик: пролог, проверки, ответ
rcall __route_1 0x4003e5 0x40048f __str_cmp сравнение строк (== , <)
# GET /rooms/{id}/bookings (__route_2): filter по всем броням, sort_by
range __route_2 0x400590 0x4006fd обработчик: пролог, проверки, ответ
range __route_2 0x4006fd 0x4007b4 цикл filter и лямбда
range __route_2 0x4007b4 0x40082a sort_by
range __route_2 0x40082a 0x400870 обработчик: пролог, проверки, ответ
rcall __route_2 0x4006fd 0x4007b4 __list_new промежуточные списки фильтров
rcall __route_2 0x4006fd 0x4007b4 __list_push промежуточные списки фильтров
rcall __route_2 0x4006fd 0x4007b4 __str_cmp сравнение строк (== , <)
fn __route_0 обработчик: пролог, проверки, ответ
fn __route_3 обработчик: пролог, проверки, ответ
fn __json_decode JSON: разбор тела запроса
fn parse_time время: parse_time, parse_date, time_iso
fn time_iso время: parse_time, parse_date, time_iso
fn __parse_ymd время: parse_time, parse_date, time_iso
fn __map_has map[int]: has
