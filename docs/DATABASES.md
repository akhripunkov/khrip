# MongoDB и ClickHouse

Прямые драйверы написаны на Khrip и входят в стандартную библиотеку. Приложения
остаются статическими Linux x86-64 ELF без libc, внешнего драйвера и отдельного
процесса-посредника. Неиспользуемые функции не попадают в исполняемый файл.

Подключения задаются значениями `Mongo` и `ChConfig`: одна программа может
обращаться к нескольким базам, в том числе одновременно с PostgreSQL.
Ожидание сети использует сопрограммы рантайма; блокировка `store` отпускается
на время операции. Значения `store` после такого вызова следует читать заново.

Это первая реализация драйверов с явно ограниченными возможностями. Она не
обещает совместимости со всем API официальных MongoDB/ClickHouse-драйверов.
Проверенные сценарии перечислены ниже; сравнительных замеров производительности
пока нет.

Фрагменты с `let` ниже предназначены для тела функции или `route`.
Полные программы находятся в `examples/databases/`.

## MongoDB

Протокол OP_MSG, BSON, SCRAM-SHA-256, TLS 1.3 с проверкой сертификата и имени
сервера. Поддерживается MongoDB 6+ через один прямой IPv4-адрес или DNS-имя.
Реплика требует
`directConnection=true` и подключения к текущему primary. Автоматического поиска
primary, DNS SRV, клиентских сессий, транзакций и retryable writes пока нет.
Неизвестные параметры URI отклоняются, а не игнорируются.

```khrip
type Event { _id: int, title: str, tags: [str] }

let primary = Mongo {
    uri: env("MONGODB_URI") ?? "mongodb://127.0.0.1:27017/app?directConnection=true",
    timeout_ms: 5000
}
let saved = mongo_insert(primary, "app", "events", [
    to_bson(Event { _id: 1, title: "hello", tags: ["demo"] })
])
if saved.error != "" {
    eprint(saved.error)
}
```

`to_bson(value)` принимает структуру или `map[str, T]`, возвращает `Bson` с полями
`data` и `error`. `from_bson(document)` выводит ожидаемый тип из аннотации:
`let event: Event? = from_bson(document)`. При несовпадении типов возвращается
`none`, причина доступна через `bson_error()`. Данные идут непосредственно в BSON.
Промежуточного преобразования в JSON нет.

Точные BSON-типы представлены обёртками:

| Тип Khrip | BSON |
|---|---|
| `int`, `float`, `bool`, `str` | Int64, Double, Boolean, UTF-8 String |
| `[T]`, структура, `map[str, T]`, `T?` | Array, Document, Document, значение или Null |
| `BsonObjectId { hex }` | ObjectId (24 шестнадцатеричных символа) |
| `BsonDate { milliseconds }` | Date (миллисекунды Unix) |
| `BsonBinary { data, subtype }` | Binary |
| `BsonDecimal128 { bytes }` | Decimal128: 16 точных байт; арифметика не реализована |
| `BsonTimestamp { increment, seconds }` | Timestamp |

Для фильтров, обновлений, индексов и команд служат `bson_new`, `bson_int`,
`bson_str`, `bson_bool`, `bson_doc`, `bson_array`, `bson_null`, `bson_finish`.
Ключи и значения проверяются; переданное значение не интерпретируется как
оператор MongoDB. Имена операторов задаёт программа.

```khrip
let filter = bson_new()
bson_int(filter, "_id", 1)
let fields = bson_new()
bson_str(fields, "title", "updated")
let update = bson_new()
bson_doc(update, "$set", bson_finish(fields))
let changed = mongo_update(primary, "app", "events",
    bson_finish(filter), bson_finish(update))
```

Основные операции:

- `mongo_command(client, database, command)` — произвольная BSON-команда;
- `mongo_insert(client, database, collection, documents, ordered=true)`;
- `mongo_update(client, database, collection, filter, update, many=false, upsert=false)`;
- `mongo_delete(client, database, collection, filter, many=false)`;
- `mongo_find(client, database, collection, filter, batch_size=100, limit=0)`;
- `mongo_cursor(client, database, collection, command)` — собственный `find`
  с проекцией/сортировкой или `aggregate` с конвейером;
- `mongo_next(cursor)` — получить следующую порцию;
- `mongo_close(cursor)` — закрыть незавершённый серверный курсор.

У курсора есть `documents: [Bson]`, `id`, `error`, `code`. Сначала обработайте
`documents` после `mongo_find`, затем вызывайте `mongo_next`. После цикла проверьте
`cursor.error`. При раннем выходе вызовите `mongo_close`. Порции уменьшают размер
одного сетевого ответа; выделенные объекты остаются в арене до конца запроса.
Это не поток с постоянным расходом памяти.
`mongo_find` и `mongo_cursor` принимают последний параметр `max_bytes`
(по умолчанию 64 МиБ): это бюджет суммарного BSON-объёма порций курсора,
а не точная оценка памяти декодированных объектов. При превышении драйвер
пытается закрыть серверный курсор и возвращает ошибку.

У `MongoResult` есть `document`, `error`, `code`, `unknown_outcome`. Последнее
поле означает, что запись могла выполниться, хотя подтверждение не получено.
Автоматических повторов нет. Для повторяемых прикладных операций используйте
идемпотентный ключ и соответствующее ограничение в базе.
Неподтверждаемые записи (`writeConcern.w=0`) отклоняются.

Пул хранит до 32 соединений на рабочий поток; соединения разделены по полному
URI, включая аутентификацию. Ограничение сообщения задаётся
`max_message_bytes` (по умолчанию 48 000 000, максимум 64 МиБ); BSON-документ —
до 16 МиБ. Вставка сейчас передаёт массив документов внутри одной команды:
разбивайте большие наборы на пакеты, помещающиеся в этот предел.

Поддержанные параметры URI: `authSource`, `authMechanism=SCRAM-SHA-256`,
`directConnection=true`, `tls`, `tlsCAFile`. Пароль SCRAM пока должен состоять из
печатных ASCII-символов: Unicode SASLprep не реализован. TLS требует сервера,
поддерживающего TLS 1.3. Компрессия протокола не реализована.

## ClickHouse

HTTP(S), переиспользование соединений, бинарные пакеты
`RowBinaryWithNamesAndTypes`. Имена и типы в заголовке пакета позволяют проверить
соответствие схеме до интерпретации двоичных значений.
Адрес задаётся без пользовательских query-параметров и credentials;
аутентификация — в `ChConfig`. Используется IPv4/DNS, прокси не поддерживается.

```khrip
type Event { id: int, title: str, score: float, tags: [str] }
let analytics = ChConfig {
    url: env("CLICKHOUSE_URL") ?? "http://127.0.0.1:8123/",
    database: "analytics",
    user: env("CLICKHOUSE_USER") ?? "default",
    password: env("CLICKHOUSE_PASSWORD") ?? ""
}
let result = ch_query_params(analytics,
    "SELECT id,title,score,tags FROM events WHERE id >= \{min:Int64} ORDER BY id LIMIT 1000",
    {"min": "10"})
if result.ok {
    let events: [Event]? = ch_decode(result.body)
    if events == none { eprint(ch_error()) }
}
```

В обычной строке Khrip литеральная `{` экранируется как `\{`; в сырой строке
между обратными кавычками экранирование не требуется. Параметры `{name:Type}`
обрабатывает ClickHouse. `ch_query_params` передаёт их отдельно от SQL;
конкатенацию пользовательского ввода в запрос использовать не следует.

- `ch_query(config, query)` — запрос без параметров;
- `ch_query_params(config, query, params: map[str, str])` — запрос с параметрами;
- `ch_encode(rows)` — бинарный пакет, имена полей и типы выводятся из `[T]`;
- `ch_insert(config, table, ch_encode(rows))` — пакетная вставка;
- `ch_decode(body)` — типизированный результат `[T]?`;
- `ch_cancel(config, query_id)` — явная отмена, требует права `KILL QUERY`.

`ChResult` содержит `ok`, `status`, `body`, `error`, `query_id`, `unknown_outcome`.
При потере подтверждения после начала отправки `unknown_outcome=true`.
Проверяйте `ok`
перед декодированием, затем результат `ch_decode`. При ошибке `ch_encode`
возвращает пустую строку, причина доступна через `ch_error()`; корректный пакет
из нуля строк содержит непустой заголовок. Отмена и разрыв соединения
не гарантируют отката уже выполненной вставки. Драйвер не повторяет запросы.

Поля строк поддерживают `int`/Int64, `float`/Float64, `bool`/Bool, `str`/String,
Nullable и Array поддержанных типов. При чтении также принимаются более узкие
целые; UInt64 за пределами signed Int64 отклоняется. Поля результата
сопоставляются по именам, порядок столбцов может отличаться. Для DateTime,
Decimal, UUID, Tuple и других специальных типов используйте явное преобразование
в запросе; точные специализированные кодеки пока не реализованы.
При кодировании списка скаляров единственный столбец получает имя `value`.

`timeout_ms` по умолчанию 10 000. `max_request_bytes` и `max_response_bytes` —
16 МиБ каждый, настраиваются до 128 МиБ. Ответ материализуется в памяти в
пределах лимита. HTTP читается порциями с проверкой длины, chunked framing,
обрывов, заголовков и трейлеров. Для обнаружения ошибок выполнения включено
`wait_end_of_query=1`; заголовки прогресса отключены. Полный объём результатов
может буферизоваться на сервере. Неограниченного потокового курсора пока нет.

`max_inflight` (по умолчанию 32, от 1 до 128) ограничивает число активных
операций ClickHouse на рабочий поток. Счётчик общий для конфигураций этого
потока; при разных лимитах запрос ждёт, пока общий счётчик станет меньше его
лимита. Ожидание входит в `timeout_ms`. Лимиты байтов относятся к передаваемым
данным; декодированные объекты и служебные структуры занимают дополнительную
память в арене.

`async_insert=true` включает серверное пакетирование с
`wait_for_async_insert=1`: операция ждёт подтверждения записи. Клиентское
пакетирование управляется размером списка для `ch_encode`. Native TCP,
колоночный Native и сжатие пока не реализованы.

## Транзакции и диагностика

Сетевые операции обоих драйверов запрещены внутри повторяемого PostgreSQL `tx`,
включая вызовы через пользовательские функции и методы. Чистые BSON/RowBinary
кодеки внутри `tx` разрешены. Общей транзакции между базами нет.

Блокировки соединений и дескрипторы незавершённых операций хранятся отдельно
для каждой сопрограммы. При `panic` или `fail` активное соединение закрывается
до освобождения арены запроса. Пулы и их сетевые буферы живут вне арены.

## Проверка

На Linux после `bash build.sh`:

```sh
bash tests/mongo.sh
bash tests/clickhouse.sh
bash tests/databases/compiler.sh
bash tests/databases/runtime.sh
```

Кодеки и проверки повреждённых сообщений не требуют БД. `runtime.sh` проверяет
совместную работу драйверов, переключение сопрограмм и освобождение ресурсов
после `fail`/`panic` на одном и двух потоках; ему нужны оба адреса БД.
Настоящие подключения
проверяются при заданных `MONGODB_URI` и `CLICKHOUSE_URL` (также
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`). Используйте отдельную тестовую базу:
сценарии создают и удаляют временные коллекции/таблицы.

Воспроизводимый запуск на Linux и macOS с Docker:

```sh
bash tests/databases/run.sh
bash tests/databases/run.sh --all
```

Сценарий создаёт отдельную сеть, серверы с аутентификацией и Linux amd64
контейнер компилятора. Порты хоста и постоянные тома не используются. Версии
образов закреплены digest; есть переопределения `MONGODB_TEST_IMAGE` и
`CLICKHOUSE_TEST_IMAGE`. Контейнеры и сеть удаляются после завершения.

Минимальные запускаемые примеры — [MongoDB](../examples/databases/mongo.kh)
и [ClickHouse](../examples/databases/clickhouse.kh).
