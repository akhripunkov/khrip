# Общие правила категорий (catz.py); маршруты размечены в <сценарий>.spec
default HTTP: разбор, запись, цикл событий, сопрограммы
fn __map_values values(): построение списка
fn __tx_case lower(): поиск и копия
fn __str_byte_find_from contains
fn __str_eq сравнение строк (== , <)
help __str_cmp
help __memeq
fn __sort_by sort_by
fn __list_slice срез
fn __reply JSON: кодирование ответа
fn __float_to_str JSON: числа float
fn __store_lock блокировка store, барьеры, GC
fn __store_release_final блокировка store, барьеры, GC
fn __barrier блокировка store, барьеры, GC
fn __pin_acquired блокировка store, барьеры, GC
fn __alloc арена: выделение
fn __alloc_slow арена: выделение
fn __arena_end арена: сброс (обнуление rep stosb)
fn __arena_begin арена: сброс (обнуление rep stosb)
own __dispatch параметры запроса и маршрутизация
fn __query параметры запроса и маршрутизация
fn __url_decode параметры запроса и маршрутизация
fn __float_parse параметры запроса и маршрутизация
fn __parse_int параметры запроса и маршрутизация
fn __utf8_scan параметры запроса и маршрутизация
fn __path_segs параметры запроса и маршрутизация
fn __map_get_ref map[str]: поиск и запись
fn __map_set_sk map[str]: поиск и запись
fn __map_get_box map[str]: поиск и запись
