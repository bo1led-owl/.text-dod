#import "@preview/polylux:0.4.0": *
#import "@preview/zebra:0.1.0" as zebra
#import "@preview/fletcher:0.5.8" as fletcher: edge, node
#import "@preview/cetz:0.5.3" as cetz

#let fg-color = rgb("#ddd")
#let bg-color = rgb("#111")

#set document(title: [Properly Cooking with Data-Oriented Design])

#set page(
  paper: "presentation-16-9",
  margin: (top: 1.5em, left: 1.5em, right: 1.5em, bottom: 1.5em),
  fill: bg-color,
  footer: [
    #set text(18pt)
    #set align(right)
    #toolbox.slide-number
  ],
)

#set text(
  fill: fg-color,
  size: 24pt,
  font: "Source Serif 4",
  weight: 400,
)

#show raw: set text(size: 20pt, font: "Source Code Pro", weight: 400)

#show figure.caption: set text(size: 18pt)

#set footnote.entry(separator: none)
#show footnote.entry: set text(size: 18pt)

#show heading: smallcaps
#show heading: set block(above: 0em, below: 1.2em)

#set grid(align: center + horizon)

#let qr(s, w) = zebra.qrcode(s, width: w, fill: fg-color, background-fill: bg-color)

#slide[
  #set page(margin: 0pt, header: none, footer: none)

  #place(image("vergil-temen-ni-gru.jpg", height: 100%, width: 100%, fit: "cover"))

  #place(top + center, dy: 2em, [
    #set text(font: "DMC5Font", weight: 400)

    #let chrome = gradient.linear(
      white,
      gray.lighten(30%),
      gray,
      gray.darken(30%),
      angle: 86deg,
      relative: auto,
    )

    #let logo(body, size, tracking) = box[
      #set text(size: size, tracking: tracking)
      #place(dx: 0.04em, dy: 0.05em, text(fill: rgb("#000000dd"), body))
      #place(text(fill: rgb(0, 0, 0, 0), stroke: 1.6pt + rgb("#0a0a0a"), body))
      #text(fill: chrome, body)
    ]

    #logo([Properly Cooking], 100pt, 8pt)

    #logo([with Data-Oriented Design], 55pt, 3pt)
  ])
]

#slide[
  = С места в карьер

  #columns(2)[
    ```
    = a 42
    print + a 37
    = c + = b print * a 7 b
    print c 
    ```

    #colbreak()

    #only(2)[
      ```
      a = 42
      print (a + 37)
      c = (b = (print (a * 7))) + b
      print c 
      ```
    ]
  ]
]

#slide[
  = Моделируем реальность

  #set align(center)
  #fletcher.diagram(
    edge-stroke: 1pt + fg-color,

    node-stroke: 1pt + fg-color,
    node-fill: bg-color,

    node((0, 0), `print`, name: <e1>),
    node((rel: (0, 1)), `=`, name: <e2>),
    node((rel: (-1, 1)), `foo`, name: <e3>),
    node((rel: (2, 0)), `+`, name: <e4>),
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
        add: Binary, sub: Binary,
        mul: Binary, div: Binary,
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

  #align(center + horizon)[
    #grid(
      rows: (2em, 2em),
      columns: (1cm, 7cm, 16cm),
      stroke: (x, y) => if y == 0 { 1pt + fg-color },
      `t`, grid.cell(fill: bg-color.lighten(40%), []), `data`,
      [1], [7], [16],
    )
  ]
]

#slide[
  #set align(center)
  #image("not-all-cpu-operations-are-created-equal.webp", height: 100%)
]

#slide[
  = Немного о кешах

  #set align(center)

  #fletcher.diagram(
    spacing: (1cm, 1cm),

    edge-stroke: 1pt + fg-color,

    node-stroke: 1pt + fg-color,
    node-inset: 10pt,
    node-fill: bg-color,

    node((-1, 1), `L1`, stroke: none, fill: none, inset: 0pt),
    node((-1, 2), `L2`, stroke: none, fill: none, inset: 0pt),
    node((-1, 3), `L3`, stroke: none, fill: none, inset: 0pt),
    node((-1, 4), `RAM`, stroke: none, fill: none, inset: 0pt),

    node((0, -1), `Core 0`, stroke: none, fill: none, inset: 0pt),
    node((1, -1), `Core 1`, stroke: none, fill: none, inset: 0pt),
    node((2, -1), `Core 2`, stroke: none, fill: none, inset: 0pt),
    node((3, -1), `Core 3`, stroke: none, fill: none, inset: 0pt),

    node((0, 0), `EU`, width: 5em, corner-radius: 1em, name: <cpu0>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu1>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu2>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu3>),

    node((0, 1), `48K`, width: 3em, name: <cpu0l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu1l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu2l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu3l1>),

    edge(<cpu0>, <cpu0l1>, "-|>"),
    edge(<cpu1>, <cpu1l1>, "-|>"),
    edge(<cpu2>, <cpu2l1>, "-|>"),
    edge(<cpu3>, <cpu3l1>, "-|>"),

    node((0, 2), `1.3M`, width: 6em, name: <cpu0l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu1l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu2l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu3l2>),

    edge(<cpu0l1>, <cpu0l2>, "-|>"),
    edge(<cpu1l1>, <cpu1l2>, "-|>"),
    edge(<cpu2l1>, <cpu2l2>, "-|>"),
    edge(<cpu3l1>, <cpu3l2>, "-|>"),

    node(
      enclose: (<cpu0>, <cpu0l1>, <cpu0l2>),
      name: <core0>,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    node(
      enclose: (<cpu1>, <cpu1l1>, <cpu1l2>),
      name: <core1>,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    node(
      enclose: (<cpu2>, <cpu2l1>, <cpu2l2>),
      name: <core2>,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    node(
      enclose: (<cpu3>, <cpu3l1>, <cpu3l2>),
      name: <core3>,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    node((1, 3), stroke: none, width: 6em, name: <cpu1l2fake>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu2l2fake>),

    node(
      enclose: (<cpu1l2fake>, <cpu2l2fake>),
      name: <l3>,
      `24M`,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    edge(<cpu0l2>, <l3>, "-|>"),
    edge(<cpu1l2>, <l3>, "-|>"),
    edge(<cpu2l2>, <l3>, "-|>"),
    edge(<cpu3l2>, <l3>, "-|>"),

    node((0, 4), stroke: none, width: 6em, name: <cpu0l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu1l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu2l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu3l2fake2>),

    edge(<l3>, <ram>, "-|>"),

    node(
      enclose: (<cpu0l2fake2>, <cpu1l2fake2>, <cpu2l2fake2>, <cpu3l2fake2>),
      name: <ram>,
      `16G`,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),
  )
]

#slide[
  = Получается...

  #one-by-one(start: 1)[
    Мы раскидали по памяти немаленькие объекты.
  ][

    Можем ли мы лучше?
  ][
    Конечно
    #align(center)[ #image("vergil-yamato.png", height: 1fr) ]
  ]
]

#slide[
  = Действуем

  Мы *раскидали* по памяти немаленькие объекты.
]

#slide[
  = Уплотняем

  Аллокатор общего назначения:

  #let alive = grid.cell(fill: bg-color.lighten(40%), [])
  #let dead = grid.cell(fill: bg-color, [free])

  #align(center, grid(
    rows: (2em,),
    columns: (3em, 2.5em, 3em, 1em, 2em, 4em, 3em, 2em, 2em, 5em, 3em),
    inset: (x: 3em, y: 1em),
    stroke: 1pt + fg-color,
    alive, dead, alive, alive, alive, dead, dead, alive, dead, alive, alive,
  ))

  #only("2-")[
    Арена-аллокатор: // #footnote[В C++ есть `std::monotonic_buffer_resource`]:

    #align(center, grid(
      rows: (2em,),
      columns: (3em, 3em, 1em, 2em, 2em, 5em, 3em, 11.5em),
      inset: (x: 3em, y: 1em),
      stroke: 1pt + fg-color,
      alive, alive, alive, alive, alive, alive, alive, dead,
    ))
  ]
]

#slide[
  = Первые плоды

  #figure(numbering: none, caption: [1.000.000 операций глубины не более 42], image(
    "arena-bench.png",
    width: 100%,
    fit: "contain",
  ))
]

#slide[
  = Действуем

  #only(1)[
    Мы #strike([раскидали]) по памяти немаленькие объекты
  ]
  #only(2)[
    Мы плотно разложили в памяти *немаленькие* объекты
  ]
]

#slide[
  = Сокращаем

  Посмотрим на реальные входные данные:
  - Выражений не больше, чем символов в файле
  - Файл больше 4ГБ --- слишком много
    #only(1, footnote[ввод для бенчмарка на прошлом слайде занимает \~100МБ])
    $=>$ хватит 32 бит

  #only(2)[
    И сделаем выводы:
    - Заменим `*Expr` на `u32`
    - Полный диапазон значений `[]const u8` тоже не нужен, заменим на пару `u32`
  ]
]

#slide[
  = Сокращаем

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

#slide[
  = Сокращаем

  #align(center + horizon)[
    #grid(
      rows: (2em, 2em),
      columns: (2em, 14em, 16em),
      inset: (x: 3em, y: 1em),
      stroke: (x, y) => if y == 0 { 1pt + fg-color },
      `tag`, grid.cell(fill: bg-color.lighten(40%), []), `data`,
      [1], [7], [8],
    )
  ]
]

#slide[
  = Сократили...

  #figure(numbering: none, caption: [1.000.000 операций глубины не более 42], image(
    "aos-naive-bench.png",
    width: 100%,
    fit: "contain",
  ))
]

#slide[
  = Сократили...

  #set align(center)

  #grid(
    rows: (2em, 2em),
    columns: (0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 2cm),
    stroke: (x, y) => if y == 0 and x < 9 { 1pt + fg-color },
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    $dots.c.h$,
    [1], [7], [8], [1], [7], [8], [1], [7], [8], $dots.c.h$,
  )

  #image("no-motivation.jpg", height: 1fr, fit: "contain")
]

#slide[
  = Путь первый: Struct of Arrays

  #raw(lang: "zig", "std.ArrayList(Expr)")
  #align(center, grid(
    rows: (1.3em, 1.3em),
    columns: (0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 2cm),
    stroke: (x, y) => if y == 0 and x < 9 { 1pt + fg-color },
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    $dots.c.h$,
    [1], [7], [8], [1], [7], [8], [1], [7], [8], $dots.c.h$,
  ))

  #only(2)[
    #raw(lang: "zig", "std.MultiArrayList(Expr)")
    #align(center, block[
      #let columns = 24
      #grid(
        rows: (1.3em, 1.3em),
        columns: range(columns).map(_ => 1em) + (2em,),
        row-gutter: (0em, 1em, 0em, 1em),
        stroke: (x, y) => if y == 0 and x < columns { 1pt + fg-color },
        ..range(columns).map(_ => `t`), $dots.c.h$,
        ..range(columns).map(_ => [1]), $dots.c.h$,
      )

      #let columns = 3
      #grid(
        rows: (1.3em, 1.3em),
        columns: range(columns).map(_ => 8em) + (2em,),
        row-gutter: (0em, 1em, 0em, 1em),
        stroke: (x, y) => if y == 0 and x < columns { 1pt + fg-color },
        ..range(columns).map(_ => `data`), $dots.c.h$,
        ..range(columns).map(_ => [8]), $dots.c.h$,
      )
    ])
  ]
]

#slide[
  = Путь первый: Struct of Arrays

  #figure(numbering: none, caption: [1.000.000 операций глубины не более 42], image(
    "soa-bench.png",
    height: 77%,
    fit: "contain",
  ))
]

#slide[
  = Путь второй: выравнивание

  #set align(center + horizon)

  #grid(
    rows: (2em, 2em),
    columns: (0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 0.7cm, 3.2cm, 4.5cm, 2cm),
    stroke: (x, y) => if y == 0 and x < 9 { 1pt + fg-color },
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    $dots.c.h$,
    [1], [7], [8], [1], [7], [8], [1], [7], [8], $dots.c.h$,
  )
]

#slide[
  = Путь второй: выравнивание

  #set align(center + horizon)

  #only(1)[
    ```zig
    const Expr = struct {
      kind: enum(u8),
      data: union {
        number: u64, // !!!
        ...
      },
    };
    ```
  ]


  #only(2)[
    ```zig
    const Expr = struct {
      kind: enum(u8),
      data: union {
        number: [2]u32, // :)
        ...
      },
    };
    ```
  ]
]

#slide[
  = Путь второй: выравнивание

  #set align(center + horizon)

  #grid(
    rows: (2em, 2em),
    columns: (1cm, 2.01cm, 5.6cm, 1cm, 2.01cm, 5.6cm, 1cm, 2.01cm, 5.6cm, 2cm),
    stroke: (x, y) => if y == 0 and x < 9 { 1pt + fg-color },
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    `t`,
    grid.cell(fill: bg-color.lighten(40%), []),
    `data`,
    $dots.c.h$,
    [1], [3], [8], [1], [3], [8], [1], [3], [8], $dots.c.h$,
  )
]

#slide[
  = Зачёт по ассемблеру

  #set align(center)

  #columns(2)[
    ```c
    u64 load(u32* x) {
      u64 res = x[0];
      res <<= 32;
      res |= x[1];
      return res;
    }

    void store(u32* x, u64 v) {
        x[0] = v >> 32;
        x[1] = v;
    }
    ```
    #colbreak()
    ```c
    u64 load(u32* x) {
      u64 res = x[1];
      res <<= 32;
      res |= x[0];
      return res;
    }

    void store(u32* x, u64 v) {
        x[1] = v >> 32;
        x[0] = v;
    }
    ```
  ]
]

#slide[
  = Зачёт по ассемблеру

  #set align(center)
  #columns(2)[
    ```asm
    load:
    mov ecx, dword ptr [rdi]
    mov eax, dword ptr [rdi + 4]
    shl rcx, 32
    or  rax, rcx
    ret

    store:
    ror rsi, 32
    mov qword ptr [rdi], rsi
    ret
    ```
    #colbreak()
    ```asm
    load:
    mov rax, qword ptr [rdi]
    ret

    store:
    mov qword ptr [rdi], rsi
    ret
    ```
  ]
]

#slide[
  #figure(numbering: none, caption: [1.000.000 операций глубины не более 42], image(
    "aos-bench.png",
    width: 100%,
    fit: "contain",
  ))
]

#slide[
  = Takeaways

  - Главная задача каждой программы --- преобразовать даннные
  - Плотно укладывать данные --- круто
  - Решения нужно принимать на основе реальных параметров
  - Арены --- дешёвый способ выиграть производительность
]

#slide[
  = Further reading

  #let qr-width = 10cm

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
    caption: [GitHub репозиторий доклада],
    qr("https://github.com/bo1led-owl/.text-dod", 10cm),
  )
]
