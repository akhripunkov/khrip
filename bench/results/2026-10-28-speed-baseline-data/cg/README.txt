variants.tsv — команды на запрос (callgrind, THREADS=1) у всех вариантов:
  lib      — библиотека репозитория (1349342);
  libx-v1  — копия с быстрым lower и __str_contains_lower (первое имя; пустая подстрока — после проверки ASCII);
  libx     — то же, функция названа __text_contains_lower и пустая подстрока — сразу «да» (patches/libx-lower-contains.patch);
  liby     — libx + __str_cmp через ctz (patches/liby-str-cmp.patch).
  state    — для bookings: число броней при замере (в фазах с POST растёт).
Варианты-исходники — ../variants/; c0 и b0 — eval/solutions/{catalog,bookings}/khrip/main.kh.
