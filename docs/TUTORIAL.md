# Khrip за час: мини-учебник

Khrip — компилируемый язык для HTTP API. Его главная задача — чтобы нейросеть
писала бэкенд короче и с меньшим числом ошибок, а сервер работал быстро и в
малой памяти. Этот учебник — для человека: посмотреть, как выглядит код, и
попробовать самому.

Все примеры лежат в [docs/tutorial/](tutorial) и проверяются вместе с тестами
компилятора, так что код здесь настоящий. Если вы пишете на C#, в конце есть
[шпаргалка «C# → Khrip»](#шпаргалка-c--khrip).

## Урок 0. Установка и команды

Нужны только `nasm` и `ld`. Компилятор собирает сам себя из исходников:

```
./build.sh                 # зерно на ассемблере → загрузчик → khc → khc собирает сам себя
```

Дальше всё делает одна программа `build/khc`:

| Команда | Что делает |
|---|---|
| `khc run app.kh` | собрать в памяти и запустить |
| `khc test app.kh` | выполнить блоки `test` |
| `khc check app.kh` | показать все ошибки сразу, с подсказками (`--json` — для нейросетей) |
| `khc -o app app.kh` | собрать статический бинарник: один файл, без зависимостей |

## Урок 1. Переменные, функции, условия, циклы

```khrip
// Урок 1. Переменные, функции, условия, циклы.

const VAT_PERCENT = 20

// Функция: параметры с типами, результат после ->.
fn with_vat(price: int) -> int {
    return price + price * VAT_PERCENT / 100
}

// Без результата -> не пишется.
fn greet(name: str, greeting: str = "Привет") {
    print("{greeting}, {name}!")
}

fn main() {
    let name = "Анна"            // let — нельзя изменить, тип выводится: str
    var visits = 0               // var — можно изменить
    visits += 1

    greet(name)
    greet("Борис", "Здравствуйте")
    print("Цена с НДС: {with_vat(1000)}")

    // if — оператор и значение
    let size = if visits > 10 { "постоянный" } else { "новый" }
    print("Гость {name}: {size}, визитов {visits}")

    // циклы
    var total = 0
    for i in 1..=5 {
        total += i
    }
    print("Сумма 1..5 = {total}")

    var n = 3
    while n > 0 {
        write("{n}… ")
        n -= 1
    }
    print("старт!")
}
```

Вывод `khc run docs/tutorial/01_basics.kh`:

```
Привет, Анна!
Здравствуйте, Борис!
Цена с НДС: 1200
Гость Анна: новый, визитов 1
Сумма 1..5 = 15
3… 2… 1… старт!
```

Что здесь важно:

- `let` нельзя изменить, `var` — можно. Тип выводится сам: `let name = "Анна"` — это `str`.
- Параметры функции пишутся `имя: тип`, результат — после `->`. У параметра может
  быть значение по умолчанию: `greeting: str = "Привет"`.
- `"{name}"` подставляет любое выражение в строку.
- `if` — ещё и значение: `let size = if ... { "a" } else { "b" }`.
- `0..n` — без `n`, `0..=n` — включая `n`. Вместо `++` пишется `+= 1`.
- Переполнение `int` и деление на ноль не проходят молча: программа завершается с
  кодом 101 и местом ошибки, а в сервере запрос получает 500.

**Задание.** Напишите `fizzbuzz(n: int) -> str`: «Fizz» для кратных 3, «Buzz» для
кратных 5, «FizzBuzz» для кратных 15, иначе само число. Выведите результаты для 1..15
через пробел.

<details><summary>Ответ</summary>

```khrip
// Ответ к заданию урока 1.
fn fizzbuzz(n: int) -> str {
    if n % 15 == 0 {
        return "FizzBuzz"
    }
    if n % 3 == 0 {
        return "Fizz"
    }
    if n % 5 == 0 {
        return "Buzz"
    }
    return n.to_str()
}

fn main() {
    var parts: [str] = []
    for i in 1..=15 {
        parts.push(fizzbuzz(i))
    }
    print(parts.join(" "))
}
```

```
1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz
```

</details>

## Урок 2. Списки, словари, лямбды

```khrip
// Урок 2. Списки, словари, лямбды.

fn main() {
    // список
    var prices = [120, 450, 80, 990]
    prices.push(300)
    print("Цен: {prices.len()}, первая {prices[0]}, последняя {prices.last()}")

    // методы с лямбдами: x => выражение
    let cheap = prices.filter(p => p < 400)
    let doubled = prices.map(p => p * 2)
    print("Дешёвые: {to_json(cheap)}, удвоенные: {to_json(doubled)}")
    print("Есть дороже 900: {prices.any(p => p > 900)}, сумма: {prices.sum()}")

    // индекс и элемент
    for i, p in prices {
        if p > 400 {
            print("  дорогая цена №{i}: {p}")
        }
    }

    // словарь: ключ int или str; порядок — как добавляли
    var stock: map[str, int] = {}
    stock["яблоки"] = 12
    stock["груши"] = 0
    stock["сливы"] = 7
    for fruit, count in stock {
        print("  {fruit}: {count}")
    }

    // m[k] возвращает int? — значения может не быть
    let kiwi = stock["киви"] ?? 0
    print("Киви: {kiwi}, есть ли груши в словаре: {stock.has("груши")}")

    // строки
    let title = "  War and Peace  ".trim()
    print("{title.upper()}: {title.len()} символов, слова: {to_json(title.split(" "))}")
    print("Срез: {title[0..3]}, с 8-го: {title[8..]}, есть ли Peace: {title.contains("Peace")}")
    // строка — байты UTF-8: у кириллицы буква занимает 2 байта
    let word = "мир"
    print("«{word}».len() = {word.len()}")
}
```

```
Цен: 5, первая 120, последняя 300
Дешёвые: [120,80,300], удвоенные: [240,900,160,1980,600]
Есть дороже 900: true, сумма: 1940
  дорогая цена №1: 450
  дорогая цена №3: 990
  яблоки: 12
  груши: 0
  сливы: 7
Киви: 0, есть ли груши в словаре: true
WAR AND PEACE: 13 символов, слова: ["War","and","Peace"]
Срез: War, с 8-го: Peace, есть ли Peace: true
«мир».len() = 6
```

Что здесь важно:

- Список — `[T]`, словарь — `map[K, V]`, где ключ `int` или `str`. Словарь отдаёт
  ключи в порядке добавления.
- Лямбды пишутся `x => выражение` и работают в `map`, `filter`, `find`, `any`, `all`,
  `count`, `sort_by`. Они видят локальные переменные вокруг.
- `m[k]` — это `int?`: значения может не быть. `?? 0` подставляет значение по
  умолчанию.
- Строки — байты UTF-8. `len()` считает байты, срезы режут по байтам: у кириллицы
  буква занимает два байта. Для текста на русском срезами пользуйтесь осторожно.
- Срез, выходящий за границы, не падает: `xs[10..20]` у короткого списка даст
  пустой список.

**Задание.** Есть оценки `{"Анна": 5, "Борис": 3, "Вера": 5, "Глеб": 4}`.
Посчитайте средний балл с двумя знаками и выведите отличников через запятую.

<details><summary>Ответ</summary>

```khrip
// Ответ к заданию урока 2.
fn main() {
    let grades = {"Анна": 5, "Борис": 3, "Вера": 5, "Глеб": 4}
    let scores = grades.values()
    let avg = scores.sum().to_float() / scores.len().to_float()
    let best = grades.keys().filter(name => (grades[name] ?? 0) == 5)
    print("Средний балл: {avg.round_to(2)}, отличники: {best.join(", ")}")
}
```

```
Средний балл: 4.25, отличники: Анна, Вера
```

</details>

## Урок 3. Свои типы, варианты, match, необязательные значения

```khrip
// Урок 3. Свои типы, варианты, match, необязательные значения.

// Структура: короткая — в одну строку
type Money { rubles: int, kopecks: int }

type NewBook {
    title: str
    author: str
    year: int
    tags: [str] = []         // значение по умолчанию
    note: str?               // необязательное поле, по умолчанию none
}

// ...NewBook — все поля NewBook плюс id
type Book { id: int, ...NewBook }

// Перечисление
type Genre = Novel | Poetry | Science

// Вариант с данными: каждый вариант со своими полями
type Payment = Cash | Card { last4: str } | Transfer { bank: str, days: int }

fn describe(p: Payment) -> str {
    // match обязан покрыть все варианты — иначе ошибка компиляции
    return match p {
        Cash => "наличными"
        Card c => "картой *{c.last4}"
        Transfer t => "переводом через {t.bank}, {t.days} дн."
    }
}

fn find_year(books: [Book], title: str) -> int? {
    let b = books.find(b => b.title == title) else {
        return none            // книги нет
    }
    return b.year
}

fn main() {
    let draft = NewBook { title: "Мастер и Маргарита", author: "Булгаков", year: 1967 }
    let book = Book { id: 1, ...draft, tags: ["роман"] }
    print(to_json(book))

    let genre = Novel
    if genre == Novel {
        print("Это роман")
    }

    for p in [Cash, Card { last4: "4242" }, Transfer { bank: "Сбер", days: 2 }] {
        print("Оплата {describe(p)}")
    }

    // T? — значение может отсутствовать
    let books = [book]
    print("Год: {find_year(books, "Мастер и Маргарита") ?? 0}")
    print("Нет книги: {find_year(books, "Идиот") ?? -1}")

    // После проверки на none переменная — обычное значение
    let note = book.note
    if note == none {
        print("Заметки нет")
    } else {
        print("Заметка: {note.upper()}")
    }

    // let ... else — достать значение или выйти
    let first = books.find(b => b.year > 1900) else {
        print("пусто")
        return
    }
    print("Первая после 1900: {first.title}")
}
```

```
{"id":1,"title":"Мастер и Маргарита","author":"Булгаков","year":1967,"tags":["роман"],"note":null}
Это роман
Оплата наличными
Оплата картой *4242
Оплата переводом через Сбер, 2 дн.
Год: 1967
Нет книги: -1
Заметки нет
Первая после 1900: Мастер и Маргарита
```

Что здесь важно:

- `type Book { ... }` — структура. `...NewBook` копирует поля другого типа — так
  описываются «новая книга» и «книга с id» без повторов.
- Значения по умолчанию (`tags: [str] = []`) и необязательные поля (`note: str?`)
  можно не указывать ни в коде, ни в JSON.
- `type Genre = Novel | Poetry | Science` — перечисление. Варианты могут нести данные:
  `Card { last4: str }`.
- `match` обязан разобрать все варианты. Забыли один — ошибка компиляции, а не
  неожиданное поведение в проде.
- `null` нет. Отсутствие значения — тип `T?` и `none`. После проверки
  `if note == none { ... } else { ... }` в ветке `else` переменная `note` уже обычная
  строка. `let x = ... else { return }` достаёт значение или выходит.

**Задание.** Опишите `type Shape = Circle { r: int } | Rect { w: int, h: int } | Square
{ side: int }` и функцию площади через `match` (π считайте равным 3). Напишите
`first_long(words: [str], min: int) -> str?` — первое слово длиной не меньше `min`.

<details><summary>Ответ</summary>

```khrip
// Ответ к заданию урока 3.
type Shape = Circle { r: int } | Rect { w: int, h: int } | Square { side: int }

fn area(s: Shape) -> int {
    return match s {
        Circle c => 3 * c.r * c.r
        Rect r => r.w * r.h
        Square q => q.side * q.side
    }
}

fn first_long(words: [str], min: int) -> str? {
    return words.find(w => w.len() >= min)
}

fn main() {
    let shapes = [Circle { r: 2 }, Rect { w: 3, h: 4 }, Square { side: 5 }]
    print("Площади: {to_json(shapes.map(s => area(s)))}")
    print("Длинное слово: {first_long(["cat", "horse", "elephant"], 5) ?? "нет"}")
    print("Очень длинное: {first_long(["cat"], 10) ?? "нет"}")
}
```

```
Площади: [12,12,25]
Длинное слово: horse
Очень длинное: нет
```

Список `[Circle { .. }, Rect { .. }, Square { .. }]` получает общий тип `[Shape]`
сам: разные варианты одного типа складываются в список этого типа.

</details>

## Урок 4. Первый API

```khrip
// Урок 4. Первый API: маршруты, данные, ответы, тесты.
// Запуск: khc run 04_api.kh (порт 8080), тесты: khc test 04_api.kh

type NewBook { title: str, author: str, year: int, tags: [str] = [] }

type Book { id: int, ...NewBook }

type BookPatch { title: str?, author: str?, year: int?, tags: [str]? }

// store — данные, которые живут между запросами
store books: map[int, Book]
store last_id: int

// Тело запроса — JSON, разбирается в NewBook автоматически.
// Если JSON неверный или нет обязательного поля — сразу 400.
route POST "/books" (body: NewBook) -> 201 Book | 400 str {
    if body.title.trim() == "" || body.year < 1450 {
        return 400 "title is required, year must be 1450 or later"
    }
    last_id += 1
    let book = Book { id: last_id, ...body }
    books[book.id] = book
    return 201 book
}

// {id} в пути — параметр; int проверяется сам: /books/abc → 400
route GET "/books/{id}" (id: int) -> Book | 404 {
    return books[id] ?? 404
}

// Параметры строки запроса: ?author=...&page=2
route GET "/books" (author: str?, tag: str?, page: int = 1) -> [Book] {
    let found = books.values()
        .filter(b => author == none || b.author == author)
        .filter(b => tag == none || b.tags.contains(tag))
        .sort_by(b => b.title)
    return found[(page - 1) * 20..page * 20]
}

// PATCH: пришедшие поля заменяют старые, остальные остаются
route PATCH "/books/{id}" (id: int, body: BookPatch) -> Book | 404 {
    let old = books[id] else {
        return 404
    }
    let book = Book { ...old, ...body }
    books[id] = book
    return book
}

route DELETE "/books/{id}" (id: int) -> 204 | 404 {
    books.remove(id) else {
        return 404
    }
    return 204
}

test "create and read" {
    let r = call POST "/books" NewBook { title: "Dune", author: "Herbert", year: 1965, tags: ["sf"] }
    expect r.status == 201
    expect r.body.contains(`"id":1`)
    expect (call GET "/books/1").status == 200
    expect (call GET "/books/99").status == 404
}

test "validation" {
    expect (call POST "/books" NewBook { title: " ", author: "X", year: 2000 }).status == 400
    expect (call POST "/books" `{"title": "No author"}`).status == 400
    expect (call GET "/books/abc").status == 400
}

test "filter, patch, delete" {
    call POST "/books" NewBook { title: "Solaris", author: "Lem", year: 1961, tags: ["sf"] }
    call POST "/books" NewBook { title: "Ulysses", author: "Joyce", year: 1922 }
    expect (call GET "/books?tag=sf").body.contains("Solaris")
    expect !(call GET "/books?author=Lem").body.contains("Dune")
    let p = call PATCH "/books/3" `{"year": 1920}`
    expect p.body.contains(`"year":1920`)
    expect p.body.contains(`"title":"Ulysses"`)
    expect (call DELETE "/books/3").status == 204
    expect (call DELETE "/books/3").status == 404
}
```

Тесты — `khc test docs/tutorial/04_api.kh`:

```
ok    create and read
ok    validation
ok    filter, patch, delete
3 tests: 3 passed, 0 failed
```

Сервер — `khc run docs/tutorial/04_api.kh` (порт 8080, переменные `PORT` и `THREADS`):

```
$ curl -s -X POST localhost:8080/books -d '{"title":"Dune","author":"Herbert","year":1965}'
{"id":1,"title":"Dune","author":"Herbert","year":1965,"tags":[]}
$ curl -s localhost:8080/books/1
{"id":1,"title":"Dune","author":"Herbert","year":1965,"tags":[]}
$ curl -s -X POST localhost:8080/books -d '{"title":"Dune"}'
invalid JSON body: missing field 'author'
$ curl -s -X PATCH localhost:8080/books/1 -d '{"year":1966}'
{"id":1,"title":"Dune","author":"Herbert","year":1966,"tags":[]}
$ curl -si localhost:8080/books/7 | head -1
HTTP/1.1 404 Not Found
```

Что здесь важно:

- `route МЕТОД "путь" (параметры) -> ответы { ... }` — весь маршрут. Компилятор сам
  разбирает путь, строку запроса и JSON-тело, проверяет типы и отвечает 400 с
  понятным текстом, если ввод неверный.
- Откуда берётся параметр, видно по типу: `{id}` в пути — из пути; структура, список
  или словарь — тело JSON; остальное — строка запроса. `author: str?` — необязательный
  параметр, `page: int = 1` — со значением по умолчанию.
- `-> 201 Book | 400 str | 404` — все возможные ответы прямо в объявлении. `return 404`
  с кодом, которого нет в объявлении, не скомпилируется.
- `store` — данные, которые живут между запросами. Запросов на нескольких ядрах много
  одновременно, но обработчик видит `store` так, будто запросы идут по одному:
  блокировки расставляют компилятор и runtime. Маршруты, которые только читают,
  выполняются параллельно.
- `Book { ...old, ...body }` в PATCH: поля `body` с типом `T?` заменяют старые, только
  если пришли в запросе.
- `test` и `call` выполняют запросы внутри процесса, без сети. `expect a == b` при
  провале показывает обе стороны.
- В обратных кавычках — строка как есть, без экранирования: удобно для JSON и
  регулярных выражений.

**Задание.** Добавьте маршрут `GET /authors` — список авторов без повторов, по
алфавиту — и тест к нему.

<details><summary>Ответ</summary>

Добавка к уроку 4 (весь файл —
[answers/4_authors.kh](tutorial/answers/4_authors.kh)):

```khrip
route GET "/authors" -> [str] {
    var names: [str] = []
    for b in books.values() {
        if !names.contains(b.author) {
            names.push(b.author)
        }
    }
    return names.sort()
}

test "authors" {
    call POST "/books" NewBook { title: "Emma", author: "Austen", year: 1815 }
    call POST "/books" NewBook { title: "Persuasion", author: "Austen", year: 1817 }
    call POST "/books" NewBook { title: "Ada", author: "Nabokov", year: 1969 }
    let r = call GET "/authors"
    expect r.body.contains(`"Austen","Herbert","Lem","Nabokov"`)
}
```

</details>

## Урок 5. Проект «Библиотека»

Читатели регистрируются и получают ключ, берут книги на 14 дней, возвращают их;
раз в час просроченные выдачи помечаются.

```khrip
// Урок 5. Проект «Библиотека»: читатели, выдача книг, просрочки.
// Ключ читателя — в заголовке X-API-Key; книги выдаются на 14 дней.

const LOAN_DAYS = 14

type NewMember { name: str, email: str }

type Member { id: int, name: str, email: str }

type Registered { member: Member, api_key: str }

type Book { id: int, title: str }

type LoanStatus = Active | Overdue | Returned

type Loan { id: int, book_id: int, member_id: int, due: str, status: LoanStatus = Active }

type NewLoan { book_id: int }

store members: map[int, Member]
store keys: map[str, int]
store books: map[int, Book]
store loans: map[int, Loan]

// Читатель по ключу из заголовка; нет ключа или он неверный — 401.
// fail завершает запрос из любой функции.
fn current_member() -> Member {
    let key = header("X-API-Key") else {
        fail(401)
    }
    let id = keys[key] ?? fail(401, "unknown key")
    return members[id] ?? fail(401)
}

route POST "/members" (body: NewMember) -> 201 Registered | 400 str {
    if body.name.trim() == "" || !body.email.matches(`[^@\s]+@[^@\s]+\.[a-z]{2,}`) {
        return 400 "name and a valid email are required"
    }
    let member = Member { id: members.len() + 1, ...body }
    let key = random_str(24)
    members[member.id] = member
    keys[key] = member.id
    return 201 Registered { member, api_key: key }
}

route POST "/books" (body: Book) -> 201 Book {
    books[body.id] = body
    return 201 body
}

route POST "/loans" (body: NewLoan) -> 201 Loan | 404 | 409 str {
    let me = current_member()
    if !books.has(body.book_id) {
        return 404
    }
    if loans.values().any(l => l.book_id == body.book_id && l.status != Returned) {
        return 409 "the book is already taken"
    }
    let loan = Loan { id: loans.len() + 1, book_id: body.book_id, member_id: me.id, due: time_iso(now() + LOAN_DAYS * 86400) }
    loans[loan.id] = loan
    return 201 loan
}

route POST "/loans/{id}/return" (id: int) -> Loan | 403 | 404 {
    let me = current_member()
    let loan = loans[id] else {
        return 404
    }
    if loan.member_id != me.id {
        return 403
    }
    loan.status = Returned
    return loan
}

route GET "/me/loans" -> [Loan] {
    let me = current_member()
    return loans.values().filter(l => l.member_id == me.id)
}

// Просрочки: проверка раз в час (и из теста — тем же вызовом)
fn mark_overdue() -> int {
    var count = 0
    let today = time_iso(now())
    for l in loans.values() {
        if l.status == Active && l.due < today {
            l.status = Overdue
            count += 1
        }
    }
    return count
}

every 1 h {
    mark_overdue()
}

test "member, loan, return" {
    call POST "/books" Book { id: 7, title: "Dune" }
    let reg = call POST "/members" NewMember { name: "Anna", email: "anna@example.com" }
    expect reg.status == 201
    let r: Registered? = from_json(reg.body)
    expect r != none
    let key = r.api_key
    expect key.len() == 24

    let auth = {"X-API-Key": key}
    expect (call POST "/loans" NewLoan { book_id: 7 }).status == 401
    let loan = call POST "/loans" NewLoan { book_id: 7 } headers auth
    expect loan.status == 201
    expect (call POST "/loans" NewLoan { book_id: 7 } headers auth).status == 409
    expect (call POST "/loans" NewLoan { book_id: 99 } headers auth).status == 404
    expect (call GET "/me/loans" headers auth).body.contains(`"status":"Active"`)
    expect (call POST "/loans/1/return" headers auth).body.contains(`"status":"Returned"`)
}

test "bad email" {
    expect (call POST "/members" NewMember { name: "Bob", email: "bob@" }).status == 400
}

test "overdue" {
    loans[50] = Loan { id: 50, book_id: 1, member_id: 1, due: "2020-01-01T00:00:00Z" }
    expect mark_overdue() == 1
    let loan = loans[50]
    expect loan != none
    expect loan.status == Overdue
}
```

```
ok    member, loan, return
ok    bad email
ok    overdue
3 tests: 3 passed, 0 failed
```

Что здесь важно:

- `header("X-API-Key")` читает заголовок запроса, `set_header` добавляет заголовок к
  ответу.
- `fail(401)` завершает запрос из любой функции: проверка доступа написана один раз
  в `current_member()`, а не в каждом маршруте.
- `random_str`, `time_iso`, `parse_time`, `hash_password`, `check_password`, `sha256` —
  встроенные функции для типичных задач бэкенда.
- `s.matches(`...`)` проверяет строку регулярным выражением целиком. Время проверки
  линейное, поэтому злой шаблон или ввод не подвесят сервер.
- `every 1 h { ... }` — фоновая задача. Её тело лучше вынести в функцию, чтобы
  проверить тестом без ожидания.
- В тестах можно менять `store` напрямую (`loans[50] = ...`): так готовятся данные
  для проверки.
- `expect r != none` в тесте: если значения нет, тест останавливается с сообщением,
  а дальше `r` читается как обычное значение (`r.api_key`).

**Задание.** Добавьте `POST /loans/{id}/extend`: продлить свою активную выдачу на 7
дней, но только один раз (повторно — 409). Подсказка: `parse_time(loan.due)` даёт
секунды, `time_iso` — обратно строку.

<details><summary>Ответ</summary>

Добавка к уроку 5: поле `extended: bool = false` в `Loan` и маршрут (весь файл —
[answers/5_extend.kh](tutorial/answers/5_extend.kh)):

```khrip
route POST "/loans/{id}/extend" (id: int) -> Loan | 403 | 404 | 409 str {
    let me = current_member()
    let loan = loans[id] else {
        return 404
    }
    if loan.member_id != me.id {
        return 403
    }
    if loan.extended || loan.status != Active {
        return 409 "only an active loan can be extended, once"
    }
    let due = parse_time(loan.due) ?? fail(500)
    loan.due = time_iso(due + 7 * 86400)
    loan.extended = true
    return loan
}

test "extend once" {
    call POST "/books" Book { id: 8, title: "Ulysses" }
    let reg = call POST "/members" NewMember { name: "Vera", email: "vera@example.com" }
    let r: Registered? = from_json(reg.body)
    expect r != none
    let auth = {"X-API-Key": r.api_key}
    let loan: Loan? = from_json((call POST "/loans" NewLoan { book_id: 8 } headers auth).body)
    expect loan != none
    let id = loan.id
    expect (call POST "/loans/{id}/extend" headers auth).status == 200
    expect (call POST "/loans/{id}/extend" headers auth).status == 409
}
```

</details>

## Урок 6. Ошибки и подсказки компилятора

Вот код, каким его мог бы написать человек или модель, привыкшие к C#:

```khrip
type Genre = Novel | Poetry | Science

type Book { id: int, title: str, genre: Genre }

store books: map[int, Book]

fn label(g: Genre) -> str {
    return match g {
        Novel => "роман"
        Poetry => "стихи"
    }
}

route GET "/books/{id}" (id: int) -> Book | 404 {
    let book = books[id]
    if book == null {
        return 404
    }
    var count: string = "1"
    count++
    return book
}
```

`khc check` показывает все ошибки сразу, у каждой — место и подсказка:

```
mistakes.kh:8:12: error: match does not handle Science
        return match g {
               ^
    hint: add an arm for each, or _ => ...
mistakes.kh:16:16: error: unknown name 'null'
        if book == null {
                   ^
    hint: Khrip has no null; use none with an optional type, e.g. let u: User? = none
mistakes.kh:19:16: error: unknown type 'string'
        var count: string = "1"
                   ^
    hint: strings are str
mistakes.kh:20:10: error: Khrip has no ++ and --
        count++
             ^
    hint: use count += 1
mistakes.kh:21:12: error: this route returns Book | 404, found Book?
        return book
               ^
    hint: the value may be none: return x ?? 404 (and declare 404)
5 errors
```

Каждая ошибка исправляется за одну итерацию: добавить ветку `Science => "наука"`,
`null` → проверка на `none` или сразу `return books[id] ?? 404`, `string` → `str`,
`count++` → `count += 1`. Для нейросетей есть `khc check --json` — те же ошибки в
виде JSON.

## Урок 7. PostgreSQL

Нужен PostgreSQL. Проще всего — в контейнере:

```
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=secret postgres:16
export DATABASE_URL=postgres://postgres:secret@localhost:5432/postgres?sslmode=disable
export KHRIP_TEST_DATABASE_URL=$DATABASE_URL
```

Та же библиотека, но книги и выдачи — в базе
([db/07_library.kh](tutorial/db/07_library.kh)):

```khrip
migration 1 `
CREATE TABLE books (
    id bigserial PRIMARY KEY,
    title text NOT NULL,
    genre text NOT NULL,
    copies int NOT NULL CHECK (copies >= 0)
);
CREATE TABLE loans (
    id bigserial PRIMARY KEY,
    book_id bigint NOT NULL REFERENCES books,
    reader text NOT NULL,
    taken_at timestamptz NOT NULL DEFAULT now()
);
`

type NewBook { title: str, genre: str, copies: int = 1 }
type Book { id: int, ...NewBook }
type Take { reader: str }
type Loan { id: int, book_id: int, reader: str, taken_at: str }

route POST "/books" (body: NewBook) -> 201 Book | 400 str {
    if body.title.trim().len() == 0 || body.copies < 0 {
        return 400 "title is required, copies >= 0"
    }
    return 201 sql "INSERT INTO books {body} RETURNING *"
}

route GET "/books/{id}" (id: int) -> Book | 404 {
    return sql "SELECT * FROM books WHERE id = {id}"
}

route GET "/books" (genre: str?) -> [Book] {
    return sql "SELECT * FROM books WHERE ({genre} IS NULL OR genre = {genre}) ORDER BY title"
}

route POST "/books/{id}/take" (id: int, body: Take) -> 201 Loan | 404 | 409 str {
    tx {
        let book: Book = sql "SELECT * FROM books WHERE id = {id}"
        if book.copies == 0 {
            return 409 "no copies left"
        }
        sql "UPDATE books SET copies = copies - 1 WHERE id = {id}"
        return 201 sql "INSERT INTO loans (book_id, reader) VALUES ({id}, {body.reader}) RETURNING *"
    }
}

test "books and loans" {
    let r = call POST "/books" NewBook { title: "Dune", genre: "sf" }
    expect r.status == 201
    let book: Book? = from_json(r.body)
    expect book != none
    expect (call POST "/books" NewBook { title: "Emma", genre: "novel", copies: 2 }).status == 201
    expect (call GET "/books?genre=sf").body.contains("Dune")
    expect !(call GET "/books?genre=sf").body.contains("Emma")
    expect (call GET "/books/999").status == 404
    expect (call POST "/books/{book.id}/take" Take { reader: "ann" }).status == 201
    let again = call POST "/books/{book.id}/take" Take { reader: "bob" }
    expect again.status == 409
    expect again.body.contains("no copies left")
    let copies: int = sql "SELECT copies FROM books WHERE id = {book.id}"
    expect copies == 0
}
```

`khc test docs/tutorial/db/07_library.kh` — тесты идут во временной схеме, которую
`khc test` создаёт и удаляет; таблицы в ней строит миграция:

```
ok    books and loans
1 tests: 1 passed, 0 failed
```

Что здесь важно:

- `migration N` — изменение схемы. Сервер применяет новые миграции при запуске по
  порядку номеров; ту, что уже применена, менять нельзя — только добавить следующую.
- `sql "..."` — запрос как есть. `{id}` уходит в базу параметром, а не текстом, так
  что подставить в SQL строку от пользователя нельзя даже по ошибке.
- Что вернёт запрос, решает ожидаемый тип: `Book` — одна строка, а если её нет —
  ответ 404 (поэтому у маршрута в объявлении есть `| 404`); `Book?` — одна или
  `none`; `[Book]` — все строки; без типа — число изменённых строк. Столбцы
  раскладываются по полям с теми же именами.
- `INSERT INTO books {body} RETURNING *` — поля `body` становятся столбцами.
- `({genre} IS NULL OR genre = {genre})` — фильтр, который работает, только если
  параметр пришёл.
- `tx { }` — транзакция SERIALIZABLE: если параллельный запрос изменил те же
  строки, база откатит её, и блок выполнится заново. Поэтому внутри нельзя то,
  что нельзя повторить: `fetch`, `sleep`, изменения `store`. Ответ со статусом
  от 400 (`return 409 ...`) откатывает транзакцию.
- Ошибки базы сами становятся ответами: дубликат или нарушение CHECK — 409, ссылка
  на несуществующую строку — 404, неверное значение — 400, база недоступна — 503.
- При запуске сервер готовит каждый `sql` на настоящей базе и сверяет типы
  столбцов с полями: если они не сходятся, сервер не запустится и скажет, где.

Привычки других языков компилятор ловит сразу. Такой код:

```khrip
migration 1 `
CREATE TABLE books (id bigserial PRIMARY KEY, title text NOT NULL, copies int NOT NULL);
`
type Book { id: int, title: str, copies: int }

route GET "/books/{id}" (id: int) -> Book {
    return sql "SELECT * FROM books WHERE id = $1"
}

route GET "/books" (title: str?) -> [Book] {
    return sql "SELECT * FROM books WHERE title = {title} LIMIT 10"
}

route POST "/books/{id}/take" (id: int) -> 204 | 404 | 409 {
    let book: Book = sql "SELECT * FROM books WHERE id = {id}"
    if book.copies == 0 {
        return 409
    }
    sql "UPDATE books SET copies = copies - 1 WHERE id = {id}"
    return 204
}
```

`khc check` отвечает:

```
mistakes.kh:7:12: error: values go in place in sql: WHERE id = {id}, not $1
        return sql "SELECT * FROM books WHERE id = $1"
               ^
    hint: every {expression} is sent as a parameter, never as SQL text
mistakes.kh:11:51: error: {title} may be none, and a comparison with NULL is never true: rows would silently not match
        return sql "SELECT * FROM books WHERE title = {title} LIMIT 10"
                                                      ^
    hint: write ({title} IS NULL OR column = {title}), or unwrap it first: let v = title else { return 400 }
mistakes.kh:19:5: error: this write runs outside tx and another statement runs before it: another request can change the data in between
        sql "UPDATE books SET copies = copies - 1 WHERE id = {id}"
        ^
    hint: put the statements of this request in tx { ... }
3 errors
```

Последняя ошибка — гонка: между проверкой `copies` и `UPDATE` другой запрос мог
взять последний экземпляр. Внутри `tx { }` этого не случится.

**Задание.** Добавьте `POST /loans/{id}/return`: удаляет выдачу и возвращает
экземпляр книги; неизвестная выдача — 404.

<details><summary>Ответ</summary>

Добавка к уроку 7 (весь файл —
[db/answers/7_return.kh](tutorial/db/answers/7_return.kh)):

```khrip
route POST "/loans/{id}/return" (id: int) -> 204 | 404 {
    tx {
        let loan: Loan = sql "DELETE FROM loans WHERE id = {id} RETURNING *"
        sql "UPDATE books SET copies = copies + 1 WHERE id = {loan.book_id}"
    }
    return 204
}

test "return a book" {
    let r = call POST "/books" NewBook { title: "Ulysses", genre: "novel" }
    let book: Book? = from_json(r.body)
    expect book != none
    let t = call POST "/books/{book.id}/take" Take { reader: "cid" }
    let loan: Loan? = from_json(t.body)
    expect loan != none
    expect (call POST "/loans/{loan.id}/return").status == 204
    expect (call POST "/loans/{loan.id}/return").status == 404
    expect (call GET "/books/{book.id}").body.contains("\"copies\":1")
}
```

`DELETE ... RETURNING *` в тип `Loan` — нет такой выдачи, значит 404, и `UPDATE`
не выполнится.

</details>

## Шпаргалка «C# → Khrip»

| C# | Khrip |
|---|---|
| `var x = 1;` / `int x = 1;` | `let x = 1` (нельзя менять) или `var x = 1` |
| `string`, `List<T>`, `Dictionary<K, V>` | `str`, `[T]`, `map[K, V]` |
| `null`, `int?`, `x ?? 0` | `none`, `int?`, `x ?? 0` |
| `class` / `record` | `type User { id: int, name: str }` |
| `enum Role { Admin, Member }` | `type Role = Admin \| Member` |
| `switch` с `when` | `match` — обязан покрыть все варианты |
| `cond ? a : b` | `if cond { a } else { b }` |
| `x++` | `x += 1` |
| `items.Where(x => ...).Select(x => ...)` | `items.filter(x => ...).map(x => ...)` |
| `items.OrderBy(x => x.Name)` | `items.sort_by(x => x.name)` |
| `$"Hello {name}"` | `"Hello {name}"` |
| `@"C:\path"` | `` `C:\path` `` |
| `[HttpGet("/users/{id}")]` + контроллер | `route GET "/users/{id}" (id: int) -> User \| 404 { ... }` |
| `return NotFound();` | `return 404` |
| `throw new HttpException(401)` | `fail(401)` |
| `lock (gate) { ... }` | не нужен: `store` защищён автоматически |
| xUnit + WebApplicationFactory | `test "..." { let r = call GET "/x"; expect r.status == 200 }` |
| `async`/`await`, `Task.Delay` | не нужны: `fetch` и `sleep(ms)` — обычные вызовы, пока запрос ждёт, поток выполняет другие |
| Dapper: `QueryAsync<User>("... WHERE id = @id", new { id })` | `let u: User? = sql "... WHERE id = {id}"` |
| `BeginTransaction()` / `Commit()` | `tx { ... }` — SERIALIZABLE, повтор при конфликте |
| миграции EF Core | `` migration 2 `ALTER TABLE ...` `` |
| `using`, `namespace`, NuGet | не нужны: один проект — одно пространство имён |

## Чего пока нет

- **Других баз и очередей** (MySQL, Redis, Kafka): из баз — только PostgreSQL.
- **Освобождения старых значений в `store`:** при постоянных обновлениях память растёт.
- **Строк с учётом Юникода:** длина и срезы — в байтах.
- **TLS 1.2 и TLS на стороне сервера:** `fetch` умеет только TLS 1.3, сервер Khrip
  работает за обратным прокси.
- **Модулей, обобщённых типов, наследования и исключений** — сознательно.

## Что читать дальше

- [KHRIP.md](KHRIP.md) — полное описание языка (для промпта нейросети, англ.).
- [eval/](../eval/README.md) — одиннадцать задач бэкенда (три — на PostgreSQL), решённых на Khrip, Go, C# и Python,
  с замерами токенов, скорости и памяти.
- [examples/weather/weather.kh](../examples/weather/weather.kh) — погодный бэкенд:
  внешний API, подписки, фоновые проверки, вебхуки.
