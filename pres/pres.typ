#import "@preview/polylux:0.4.0": *
#import "@preview/zebra:0.1.0" as zebra
#import "@preview/fletcher:0.5.8" as fletcher: edge, node

#let fg-color = white.darken(10%)
#let bg-color = black.lighten(7%)

#set page(
  paper: "presentation-16-9",
  margin: (left: 2em, right: 2em, top: 2em, bottom: 2em),
  fill: bg-color,
  footer: [
    #set text(14pt)
    #set align(right)
    #toolbox.slide-number
  ],
)

#let qr = (s, w) => zebra.qrcode(s, width: w, fill: fg-color, background-fill: bg-color)

#set text(
  fill: fg-color,
  size: 18pt,
  font: "Source Serif 4",
  weight: 300,
)
#show figure.caption: set text(size: 16pt)
#show raw: set text(size: 18pt, font: "Source Code Pro", weight: 400)
#set grid(align: center + horizon)
#set footnote.entry(separator: none)
#show heading: smallcaps
#show heading: set block(above: 0em, below: 1.2em)
#set quote(block: true)

#set document(title: [properly cooking with data-oriented design])

#slide[
  #set page(footer: none)
  #set align(horizon)

  #title()
]

#slide[
  = С места в карьер

  Демонстративная задача: реализовать интерпретатор для языка
  ```bnf
  program := stmt*
  stmt    := expr "\n"
  expr    := "print" expr | op expr expr | name | number
  op      := "=" | "+" | "-" | "*" | "/"
  ```

  #only("2-")[
    Пример программы:
    ```
    = a 42                   # a = 42
    print + a 37             # print (a + 37)
    = c + = b print * a 7 b  # c = (b = (print a * 7)) + b
    print c 
    ```
  ]
]

#slide[
  = Моделируем реальность

  #set align(center + horizon)
  #fletcher.diagram(
    edge-stroke: 1pt + fg-color,

    node-stroke: 1pt + fg-color,
    node-inset: 10pt,
    node-fill: bg-color,

    node((0, 0), `print`, name: <e1>),
    node((rel: (0, 1)), $=$, name: <e2>),
    node((rel: (-1, 1)), `foo`, name: <e3>),
    node((rel: (2, 0)), $+$, name: <e4>),
    node((rel: (-1, 1)), $dots.h.c$, name: <e5>, stroke: none),
    node((rel: (2, 0)), $dots.h.c$, name: <e6>, stroke: none),

    edge(<e1>, <e2>, "-|>"),
    edge(<e2>, <e3>, "-|>"),
    edge(<e2>, <e4>, "-|>"),
    edge(<e4>, <e5>, "-|>"),
    edge(<e4>, <e6>, "-|>"),
  )
]

#slide[
  = Моделируем реальность

  #align(center)[
    ```zig
    const Expr = union(enum) { // tagged union
        number: u64,
        var_ref: []const u8,
        print: *Expr,
        add: Binary,
        sub: Binary,
        mul: Binary,
        div: Binary,
        assign: Binary,

        const Binary = struct { lhs: *Expr, rhs: *Expr },

        // recursive `free` (a lot of extra work!)
        fn deinit(self: *Expr, gpa: std.mem.Allocator) void { ... }
    };
    ```
  ]
]

#slide[
  = Минутка арифметики

  #only("1-")[
    Размер? Выравнивание?
  ]

  #only("2-")[
    #align(center)[
      #grid(
        rows: (2em, 2em),
        columns: (2em, 10em, 18em),
        inset: (x: 3em, y: 1em),
        stroke: (x, y) => if y == 0 { 1pt + fg-color },
        [tag], grid.cell(fill: bg-color.lighten(40%), []), [data],
        [1], [7], [16],
      )
    ]
  ]

  #only("3-")[
    24 и 8 байт соответственно.
  ]
]

#slide[
  #set align(center)
  #image("not-all-cpu-operations-are-created-equal.webp", height: 100%)
]

#slide[
  = Получается...

  #one-by-one(start: 1)[
    Компьютеру не нравится ходить в память, а мы раскидали
    #only(1)[#footnote[если вы хотите возразить про арену, напомните в конце доклада]]
    по ней объекты.
  ][

    Можем ли мы лучше?
  ][
    Конечно
    #align(center)[ #image("vergil.png", height: 62%) ]
  ]
]

#slide[
  = Так что же делать?


  Вычисления быстрые, память медленная $=>$ улучшим раскладку данных.

  #only(2)[
    Foreshadowing (на миллионе top-level выражений глубины не более 42):
    #align(center)[ #image("res.png", height: 62%) ]
  ]
]

#slide[
  = Так что же делать?

  Посмотрим на реальные входные данные:
  - Выражений не больше, чем символов в файле.
  - Файл больше 4ГБ --- слишком много
    #only(1, footnote[ввод для бенчмарка на прошлом слайде занимает \~100МБ])
    $=>$ хватит 32 бит.

  #only("2-")[
    И сделаем выводы:
    - Заменим `*Expr` на `u32`.
    - Полный диапазон значений `[]const u8` тоже не нужен, заменим на пару `u32`.
  ]
]

#slide[
  = Пакуем

  #only(1)[
    #align(center)[
      ```zig
      const Expr = struct {
        kind: enum(u8),
        data: union {
          number: u64,
          name: Name,
          unary: Expr.Index,
          binary: Binary,
        },
        
        const Index  = enum(u32) { _ };
        const Name   = struct { begin: u32, len: u32 };
        const Binary = struct { lhs: Expr.Index, rhs: Expr.Index };
      };
      ```
    ]
  ]

  #only("2-")[
    Размер? Выравнивание?
  ]

  #only("3-")[
    #align(center)[
      #grid(
        rows: (2em, 2em),
        columns: (2em, 14em, 16em),
        inset: (x: 3em, y: 1em),
        stroke: (x, y) => if y == 0 { 1pt + fg-color },
        [tag], grid.cell(fill: bg-color.lighten(40%), []), [data],
        [1], [7], [8],
      )
    ]
  ]

  #only("4-")[
    16 и 8 байт соответственно.
  ]
]

#slide[
  = Пакуем дальше

  Так как мы заменили указатели на индексы, придётся хранить выражения в массиве.

  #only("2-")[ А индексация позволит избавиться от семибайтной дыры в каждом объекте.  ]

  #columns(2)[
    #only("3-")[
      Было бы:
      ```zig
      exprs: std.ArrayList(Expr);
      ```
    ]

    #only("4-")[
      #grid(
        rows: (2em, 2em),
        columns: (1em, 3em, 4em, 1em, 3em, 4em, 2em),
        inset: (x: 3em, y: 1em),
        stroke: (x, y) => if y == 0 and x < 6 { 1pt + fg-color },
        [t],
        grid.cell(fill: bg-color.lighten(40%), []),
        [data],
        [t],
        grid.cell(fill: bg-color.lighten(40%), []),
        [data],
        $dots.c.h$,
        [1], [7], [8], [1], [7], [8], $dots.c.h$,
      )
    ]

    #colbreak()

    #only("5-")[
      Сделаем:
      ```zig
      exprs: std.MultiArrayList(Expr);
      ```
    ]

    #only("6-")[
      #block[
        #grid(
          rows: (2em, 2em),
          columns: (1em, 1em, 1em, 1em, 2em),
          inset: (x: 3em, y: 1em),
          row-gutter: (0em, 1em, 0em, 1em),
          stroke: (x, y) => if y == 0 and x < 4 { 1pt + fg-color },
          ..range(4).map(_ => [t]), $dots.c.h$,
          ..range(4).map(_ => [1]), $dots.c.h$,
        )

        #grid(
          rows: (2em, 2em),
          columns: (4em, 4em, 4em, 4em, 2em),
          inset: (x: 3em, y: 1em),
          row-gutter: (0em, 1em, 0em, 1em),
          stroke: (x, y) => if y == 0 and x < 4 { 1pt + fg-color },
          ..range(4).map(_ => [data]), $dots.c.h$,
          ..range(4).map(_ => [8]), $dots.c.h$,
        )
      ]
    ]
  ]
]

#slide[
  = We cooked

  Раньше объекты занимали 24 байта, теперь --- 9. Почти в три раза меньше!

  #align(center, image("vergil-cooking.png", height: 70%))
]

#slide[
  = We cooked

  #figure(numbering: none, caption: [50.000 операций глубины не более 16], image("res-small.png", width: 100%))
]

#slide[
  = We cooked

  #figure(numbering: none, caption: [1.000.000 операций глубины не более 42], image("res.png", width: 100%))
]

#slide[
  = Takeaways

  - Главная задача каждой программы --- преобразовать даннные.
  - Помните о данных, с которыми работаете, принимайте решения на этой почве.
  - Пакуйте данные плотнее.

  // TODO: more takeaways
]

#slide[
  = Further reading

  #let qr-width = 16em

  #columns(2)[
    #figure(
      numbering: none,
      caption: [Andrew Kelley: A Practical Guide to Applying Data Oriented Design (DoD)],
      qr("https://youtu.be/IroPQ150F6c", qr-width),
    )
    #colbreak()
    #figure(
      numbering: none,
      caption: [CppCon 2014: Mike Acton "Data-Oriented Design and C++"],
      qr("https://youtu.be/rX0ItVEVjHc", qr-width),
    )
  ]
]

#slide[
  = Материалы

  #figure(
    numbering: none,
    caption: [Исходники к докладу],
    qr("https://github.com/bo1led-owl/.text-dod", 16em),
  )
]

#slide[
  = Если осталось время: арены

  Если уложить выражения и идентификаторы в арены:
  #image("arena-all-res.png", height: 60%)
]

#slide[
  = Если осталось время: изоляция для бенчмарка

  Мне, конечно, очень нравится идея с калькулятором, но есть одно "но":

  #only("2-")[
    #align(center)[ #image("parsing-timings.png", width: 100%) ]
  ]

  #only("3-")[
    Парсинг текстового представления чудовищно медленный, а потому очень сильно искажал результаты замеров.

    Поэтому показанные замеры сделаны после преобразования текстового представления в кастомный байт-код.
  ]
]
