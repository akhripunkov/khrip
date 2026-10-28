# GET /products (__route_3) — адреса из дизассемблера build/khc 1349342 (catalog)
range __route_3 0x400560 0x400622 обработчик: пролог, проверки, ответ
range __route_3 0x400622 0x4006d0 цикл фильтра 1 (name/q) и лямбда
range __route_3 0x4006d0 0x400793 цикл фильтра 2 (category) и лямбда
range __route_3 0x400793 0x400852 цикл фильтра 3 (tag) и лямбда
range __route_3 0x400852 0x400920 цикл фильтра 4 (min_price) и лямбда
range __route_3 0x400920 0x4009ee цикл фильтра 5 (max_price) и лямбда
range __route_3 0x4009ee 0x400cbf sort_by
range __route_3 0x400cbf 0x400d90 обработчик: пролог, проверки, ответ
rcall __route_3 0x400606 0x4009ee __list_new промежуточные списки фильтров
rcall __route_3 0x400606 0x4009ee __list_push промежуточные списки фильтров
# GET /categories (__route_4): свёртка в map[str, Category], затем values, map, sort_by
range __route_4 0x400d90 0x400f12 /categories: цикл свёртки
range __route_4 0x400f12 0x401146 /categories: map(...) и round_to
range __route_4 0x401146 0x4011a1 sort_by
range __route_4 0x4011a1 0x401210 обработчик: пролог, проверки, ответ
fn __route_1 обработчик: пролог, проверки, ответ
fn __route_0 обработчик: пролог, проверки, ответ
fn __route_2 обработчик: пролог, проверки, ответ
