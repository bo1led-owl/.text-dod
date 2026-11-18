#import "@preview/polylux:0.4.0": *
#import "@preview/zebra:0.1.0" as zebra
#import "@preview/fletcher:0.5.8" as fletcher: edge, node
#import "@preview/lilaq:0.6.0" as lq

#let fg-color = rgb("#ddd")
#let bg-color = rgb("#111")
#let red = rgb(236, 113, 141)
#let green = rgb(68, 180, 128)
#let blue = rgb(83, 105, 170)
#let purple = rgb(180, 105, 170)
#let orange = rgb(210, 125, 70)
#let blood = rgb(210, 25, 70)

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

#set figure(numbering: none)
#show figure.caption: set text(size: 18pt)

#set footnote.entry(separator: none)
#show footnote.entry: set text(size: 18pt)

#show heading: smallcaps
#show heading: set block(above: 0em, below: 1.2em)

#set grid(align: center + horizon)

#let qr(s, w) = zebra.qrcode(s, width: w, fill: fg-color, background-fill: bg-color)

#show: lq.set-diagram(
  fill: bg-color,
  cycle: (blue, green, red).map(c => it => {
    set lq.style(fill: c)
    set lq.mark(fill: c, stroke: c)
    it
  }),
)

#show: lq.set-spine(stroke: fg-color)
#show: lq.set-tick(stroke: fg-color)
#show: lq.set-grid(stroke: bg-color.lighten(50%), stroke-sub: none)
#show: lq.set-legend(fill: bg-color, stroke: fg-color)
#show lq.selector(lq.diagram): set text(fg-color)

#let benchmark(title, impls, colors, timings) = [
  #set align(center + horizon)
  #lq.diagram(
    title: lq.title(position: bottom, dy: 2em, title),
    height: 80%,
    width: 100%,
    fill: bg-color,
    xaxis: (
      subticks: none,
      ticks: impls.enumerate(),
    ),
    yaxis: (
      label: [Время в секундах],
      subticks: none,
    ),
    lq.bar(
      fill: colors,
      range(impls.len()),
      timings,
    ),
  )
]

#let main-benchmark(n) = {
  benchmark(
    [На 100.000 выражений со средней глубиной 12.6 (129МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+").slice(0, n),
    (red, green, blue, purple, orange, blood).slice(0, n),
    (1.310, 0.903, 1.272, 1.347, 1.205, 0.867).slice(0, n),
  )
}

#slide[
  #set page(margin: 0pt, header: none, footer: none)

  #place(image("vergil-temen-ni-gru.jpg", height: 100%, width: 100%, fit: "cover"))

  #place(top + center, dy: 2em, [
    #set text(font: "DMC5Font")

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
      #place(dx: size * 0.05, dy: size * 0.045, text(fill: rgb("#000000dd"), body))
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
    print + a 67
    = c + = b print * a 7 b
    print c 
    ```

    #colbreak()

    #only(2)[
      ```
      a = 42
      print (a + 67)
      c = (b = (print (a * 7))) + b
      print c 
      ```
    ]
  ]
]

#slide[
  = С места в карьер

  ```
  / / print print / - print 4742626078375765758 14027711697529443467 * / 12802463756112957134 18132309934977557170 8608641055037238382 =  - / / 6984107485703404146 - 9916929475378643327 10919414819050606021 - 13568855607397529471 14522749415374840358 / 15862839410548134960 7323286685982528320 print =  print - + - / print =  * - = b  9769004714064862973 = c b / print print * c + 4033141316165442587 = b 14910621076775651280 + = b print + print 8610250548778301068 * 17268888967100637777 13020379258374241411 6122846502703184371 ...

  100MB more bytecode...
  ```
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
    const Expr = struct {
        kind: enum(u8) { ... },
        data: union {
            number: u64,
            name:   []const u8, // ptr + len
            unary:  *Expr,
            binary: Binary,
        },
        const Binary = struct { lhs: *Expr, rhs: *Expr, };

        // recursive `free` (a lot of extra work!)
        fn deinit(self: *Expr, gpa: std.mem.Allocator) void { ... }
    };
    ```
  ]
]

#slide[
  = Реальность \\ хешмапа

  #align(center)[
    ```zig
    const Expr = struct {
        kind: enum(u8) { ... },
        data: union {
            number: u64,
            name:   u64,
            unary:  *Expr,
            binary: Binary,
        },
        const Binary = struct { lhs: *Expr, rhs: *Expr, };

        // recursive `free` (a lot of extra work!)
        fn deinit(self: *Expr, gpa: std.mem.Allocator) void { ... }
    };
    ```
  ]
]

#slide[
  = Всё?

  Ну посчиталось всё за 1.3 секунды, ну и ладно

  #only(2)[
    #align(
      center + horizon,
      image(
        "more-power.png",
        height: 1fr,
        fit: "contain",
      ),
    )
  ]
]

#slide[
  = Что делать?

  Алгоритмически решение простое, как палка. Что делать?
]

#slide[
  = Тривиальная архитектура

  #set align(center + horizon)

  #let diagram(ram-pos, arrow-label) = fletcher.diagram(
    spacing: (1cm, 1cm),

    edge-stroke: 1pt + fg-color,

    node-stroke: 1pt + fg-color,
    node-inset: 10pt,
    node-fill: bg-color,

    node((0, 0), `EU`, width: 5em, corner-radius: 1em, name: <cpu0>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu1>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu2>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu3>),

    node((0, ram-pos), stroke: none, width: 6em, name: <cpu0l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu1l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu2l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu3l2fake2>),

    node(
      enclose: (
        <cpu0>,
        <cpu1>,
        <cpu2>,
        <cpu3>,
      ),
      name: <cpu>,
      stroke: (paint: fg-color, dash: "dashed"),
      inset: 0.7em,
      fill: none,
    ),

    node(
      enclose: (<cpu0l2fake2>, <cpu1l2fake2>, <cpu2l2fake2>, <cpu3l2fake2>),
      name: <ram>,
      `RAM`,
      shape: fletcher.shapes.rect,
      stroke: 1pt + fg-color,
    ),

    edge(<cpu0>, <cpu0l2fake2>, "<|-|>", label: arrow-label),
    edge(<cpu1>, <cpu1l2fake2>, "<|-|>"),
    edge(<cpu2>, <cpu2l2fake2>, "<|-|>"),
    edge(<cpu3>, <cpu3l2fake2>, "<|-|>"),
  )

  #only(1, diagram(2, none))
  #only(2, diagram(3.5, `100-150 cycles`))
  #only(3, diagram(5, rotate(90deg, image("half-docker.png", width: 4cm))))
]

#slide[
  = Настоящая архитектура

  #set align(center + horizon)

  #fletcher.diagram(
    spacing: (1cm, 1cm),

    edge-stroke: 1pt + fg-color,

    node-stroke: 1pt + fg-color,
    node-inset: 10pt,
    node-fill: bg-color,

    node((-1, 1), `L1`, stroke: none, fill: none, inset: 0pt),
    node((-1, 2), `L2`, stroke: none, fill: none, inset: 0pt),
    node((-1, 3), `L3`, stroke: none, fill: none, inset: 0pt),
    node((-1, 5), `RAM`, stroke: none, fill: none, inset: 0pt),

    node((0, 0), `EU`, width: 5em, corner-radius: 1em, name: <cpu0>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu1>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu2>),
    node((rel: (1, 0)), `EU`, width: 5em, corner-radius: 1em, name: <cpu3>),

    node((0, 1), `48K`, width: 3em, name: <cpu0l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu1l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu2l1>),
    node((rel: (1, 0)), `48K`, width: 3em, name: <cpu3l1>),

    node((0, 2), `1.3M`, width: 6em, name: <cpu0l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu1l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu2l2>),
    node((rel: (1, 0)), `1.3M`, width: 6em, name: <cpu3l2>),

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

    node((0, 5), stroke: none, width: 6em, name: <cpu0l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu1l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu2l2fake2>),
    node((rel: (1, 0)), stroke: none, width: 6em, name: <cpu3l2fake2>),

    node(
      enclose: (
        <cpu0>,
        <cpu1>,
        <cpu2>,
        <cpu3>,
        <cpu0l1>,
        <cpu1l1>,
        <cpu2l1>,
        <cpu3l1>,
        <cpu0l2>,
        <cpu1l2>,
        <cpu2l2>,
        <cpu3l2>,
        <l3>,
      ),
      name: <cpu>,
      stroke: (paint: fg-color, dash: "dashed"),
      inset: 0.7em,
      fill: none,
    ),

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
  = Настоящая архитектура

  #set align(center)

  ```scala
  T load(T* addr) {
    if L1.contains(addr)   // 3/1048576 chance to hit
      return L1.load(addr) // 3-4 cycles
    
    if L2.contains(addr)   // 13/163840 chance to hit
      return L2.load(addr) // 10-12 cycles

    if L3.contains(addr)   // 3/2048 chance to hit
      return L3.load(addr) // 30-70 cycles

    return RAM.load(addr)  // 100-150 cycles
  }
  ```
]

#slide[
  = А что у нас?

  #align(center)[
    ```zig
    const Expr = struct {
        kind: enum(u8) { ... },
        data: union {
            number: u64,
            name:   u64,
            unary:  *Expr,
            binary: Binary,
        },
        const Binary = struct { lhs: *Expr, rhs: *Expr, };

        // recursive `free` (a lot of extra work!)
        fn deinit(self: *Expr, gpa: std.mem.Allocator) void { ... }
    };
    ```
  ]
]

#slide[
  = Получается...

  Мы раскидали по памяти немаленькие объекты

  Можем ли мы лучше? #only(2)[
    Конечно
    #align(center)[ #image("vergil-yamato.png", height: 1fr) ]
  ]
]

#slide[
  = Действуем

  Мы _раскидали_ по памяти немаленькие объекты
]

#slide[
  = Уплотняем

  Аллокатор общего назначения:

  #let alive = grid.cell(fill: bg-color.lighten(40%), [])
  #let dead = grid.cell(fill: bg-color, [free])
  #let columns = (3em, 2.5em, 3em, 1em, 2em, 4em, 3em, 2em, 2em, 5em, 3em)

  #let gpa(..are-alive) = {
    let actual-columns = ()
    let values = ()
    let cur-column = 0em
    for (i, v) in columns.enumerate() {
      if are-alive.filter(x => x == i).len() != 0 {
        if cur-column > 0em {
          actual-columns.push(cur-column)
          values.push(dead)
        }
        cur-column = 0em
        actual-columns.push(v)
        values.push(alive)
      } else {
        cur-column += v
      }
    }

    if cur-column > 0em {
      actual-columns.push(cur-column)
      values.push(dead)
    }

    align(center, grid(
      rows: (2em,),
      columns: actual-columns,
      inset: (x: 3em, y: 1em),
      stroke: 1pt + fg-color,
      ..values,
    ))
  }

  #alternatives(
    repeat-last: true,
    gpa(),
    gpa(0),
    gpa(0, 7),
    gpa(0, 3, 7),
    gpa(0, 3, 7, 9),
    gpa(0, 3, 7, 9, 10),
    gpa(0, 2, 3, 7, 9, 10),
    gpa(0, 2, 3, 4, 7, 9, 10),
  )

  #let arena(..are-alive) = {
    let actual-columns = ()
    let values = ()

    for i in range(are-alive.len()) {
      let j = are-alive.at(i)
      actual-columns.push(columns.at(j))
      values.push(alive)
    }

    if actual-columns.len() < columns.len() {
      actual-columns.push(columns.sum() - actual-columns.sum(default: 0em))
      values.push(dead)
    }

    align(center, grid(
      rows: (2em,),
      columns: actual-columns,
      inset: (x: 3em, y: 1em),
      stroke: 1pt + fg-color,
      ..values,
    ))
  }

  #only("9-")[ Арена-аллокатор: ]
  #alternatives(
    start: 9,
    repeat-last: true,
    arena(),
    arena(0),
    arena(0, 7),
    arena(0, 7, 3),
    arena(0, 7, 3, 9),
    arena(0, 7, 3, 9, 10),
    arena(0, 7, 3, 9, 10, 2),
    arena(0, 7, 3, 9, 10, 2, 4),
  )

  #only(17)[Та же память, но быстрее и плотнее]
]

#slide[
  = Первые плоды

  #main-benchmark(2)
]

#slide[
  = Действуем

  #alternatives[
    Мы #strike([раскидали]) по памяти немаленькие объекты
  ][
    Мы плотно разложили в памяти _немаленькие_ объекты
  ]
]

#slide[
  = Что делать?

  Какого размера структура?

  #align(center)[
    ```zig
    kind: enum(u8) { ... },
    data: union {
        number: u64,
        name:   u64,
        unary:  *Expr,
        binary: Binary,   // ptr + ptr
    },
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
  = Сокращаем

  Посмотрим на реальные входные данные:
  - Выражений не больше, чем символов в файле
  - Файл больше 4ГБ --- слишком много $=>$ хватит 32 бит

  #only(2)[
    И сделаем вывод: заменим `*Expr` на `u32`
  ]
]

#slide[
  = Сокращаем

  #only(1)[
    #align(center)[
      ```zig
      const Expr = struct {
          kind: enum(u8) { ... },
          data: union {
              number:  u64,
              var_ref: u64,
              unary:   Expr.Index,
              binary:  Binary,
          },
        
        const Index  = enum(u32) { _ };
        const Binary = struct { lhs: Expr.Index, rhs: Expr.Index };
      };
      ```
    ]
  ]

  #only(2)[
    Размер?
    #align(center)[
      ```zig
      kind: enum(u8) { ... },
      data: union {
          number:  u64,
          var_ref: u64,
          unary:   Expr.Index, // u32
          binary:  Binary,     // u32 + u32
      },
      ```
    ]
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

  #main-benchmark(3)
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
  = Путь первый

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
        columns: (4em,) + range(columns).map(_ => 1em) + (2em,),
        row-gutter: (0em, 1em, 0em, 1em),
        stroke: (x, y) => if y == 0 and x > 0 and x < columns + 1 { 1pt + fg-color },
        `tags:`, ..range(columns).map(_ => `t`), $dots.c.h$,
        [], ..range(columns).map(_ => [1]), $dots.c.h$,
      )

      #let columns = 3
      #grid(
        rows: (1.3em, 1.3em),
        columns: (4em,) + range(columns).map(_ => 8em) + (2em,),
        row-gutter: (0em, 1em, 0em, 1em),
        stroke: (x, y) => if y == 0 and x > 0 and x < columns + 1 { 1pt + fg-color },
        `data:`, ..range(columns).map(_ => `data`), $dots.c.h$,
        [], ..range(columns).map(_ => [8]), $dots.c.h$,
      )
    ])
  ]
]

#slide[
  = Путь первый: Struct of Arrays

  #main-benchmark(4)
]

#slide[
  = Путь второй

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
  = Путь второй

  #set align(center + horizon)

  #alternatives[
    ```zig
    const Expr = struct {
        kind: enum(u8) { ... },
        data: union {
            number:  u64, // !!!
            var_ref: u64,
            ...
        },
    };
    ```
  ][
    ```zig
    const Expr = struct {
        kind: enum(u8) { ... },
        data: union {
            number:  [2]u32, // :)
            var_ref: [2]u32,
            ...
        },
    };
    ```
  ]

  #only(3)[
    #align(left + top)[Размер?]
    #align(top)[
      ```zig
      const Expr = struct {
          kind: enum(u8) { ... },
          data: union {
              number:  [2]u32,
              var_ref: [2]u32,
              unary:   Expr.Index, // u32
              binary:  Binary,     // u32 + u32
          },
      };
      ```
    ]
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
    // b7 b6 b5 b4 | b3 b2 b1 b0
    //     x[0]    |     x[1]

    u64 load(u32* x) {
      u64 res = x[0] << 32;
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
    // b7 b6 b5 b4 | b3 b2 b1 b0
    //     x[1]    |     x[0]

    u64 load(u32* x) {
      u64 res = x[1] << 32;
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
    ; b7 b6 b5 b4 | b3 b2 b1 b0
    ;     x[0]    |     x[1]
    load:
    mov ecx, dword ptr [rdi]
    mov eax, dword ptr [rdi + 4]
    shl rcx, 32
    or  rax, rcx
    ret
    store:
    mov dword ptr [rdi + 4], esi
    shr rsi, 32
    mov dword ptr [rdi], esi
    ret
    ```
    #colbreak()
    ```asm
    ; b7 b6 b5 b4 | b3 b2 b1 b0
    ;     x[1]    |     x[0]

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
  = Всё вместе

  #main-benchmark(5)
]

#slide[
  #set page(footer: none, margin: 0em)
  #align(center + horizon, image("reze-rain.jpg", height: 100%))
]

#slide[
  #set page(margin: 0pt, header: none, footer: none)

  #place(image("dante.jpg", height: 100%, width: auto, fit: "cover"))

  #place(top + center, dy: 2em, [
    #set text(font: "DMC5Font")

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
      #place(dx: size * 0.05, dy: size * 0.045, text(fill: rgb("#000000dd"), body))
      #place(text(fill: rgb(0, 0, 0, 0), stroke: 1.6pt + rgb("#0a0a0a"), body))
      #text(fill: chrome, body)
    ]

    #logo([Properly Cooking], 100pt, 8pt)

    #logo([Data-Oriented Design], 55pt, 3pt)
  ])
]

#slide[
  = Прожарка

  Вид операции --- всего 8 вариантов (3 бита).

  Указатель на выражение --- выровнен по 8.

  Упакуем!

  #align(center, grid(
    rows: 2em,
    columns: (20em, 2em),
    stroke: (_, y) => if y == 0 { fg-color + 1pt },
    `ptr[3:]`, `tag`,
    `61`, `3`,
  ))
]

#slide[
  = Прожарка

  #main-benchmark(6)
]

#slide[
  = Прочие бенчмарки (1.1)

  #benchmark(
    [На 5.000.000 выражений глубины 3 (264МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (2.194, 1.698, 2.316, 2.257, 1.839, 1.530),
  )
]

#slide[
  = Прочие бенчмарки (1.2)

  #benchmark(
    [На 16 выражениях глубины 27 (194МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.845, 1.421, 2.217, 2.051, 1.623, 1.259),
  )
]

#slide[
  = Массивы наносят ответный удар

  ```c
  ssize_t readv(int fildes, const struct iovec *iov, int iovcnt);
  ssize_t writev(int fildes, const struct iovec *iov, int iovcnt);

  struct iovec {
      // starting address
      void *iov_base;

      // size of the memory pointed to by `iov_base`
      size_t  iov_len;  
  };
  ```
]

#slide[
  = Прочие бенчмарки (2.0)

  #benchmark(
    [На 100.000 выражений со средней глубиной 12.6 (129-663МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.310, 0.903, 0.806, 0.634, 0.597, 0.867),
  )
]

#slide[
  = Прочие бенчмарки (2.1)

  #benchmark(
    [На 5.000.000 выражений глубины 3 (264-1300МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (2.194, 1.698, 1.183, 1.067, 1.152, 1.530),
  )
]

#slide[
  = Прочие бенчмарки (2.2)

  #benchmark(
    [На 16 выражениях глубины 27 (194-1003МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.845, 1.421, 1.168, 1.029, 0.972, 1.259),
  )
]

#slide[
  = Альтернативная задача

  Пусть теперь нам захотелось посчитать число обращений к переменным в программе.

  #only(2)[
    #columns(2)[
      ```zig
      fn count(expr: *Expr) u32 {
        return switch (expr.kind) {
          .var_ref => 1,
          .binary =>
            count(expr.lhs) +
            count(expr.rhs),
          ...
        };
      }
      ```
      #colbreak()
      ```zig
      for (exprs) |expr| {
        count += @intFromBool(
          expr.kind == .var_ref
        );
      }
      ```
    ]
  ]
]

#slide[
  = Альтернативная задача

  Идея задачи в том, чтобы показать применение SoA.

  #align(center, block[
    #let columns = 24
    #grid(
      rows: (1.3em, 1.3em),
      columns: (4em,) + range(columns).map(_ => 1em) + (2em,),
      row-gutter: (0em, 1em, 0em, 1em),
      stroke: (x, y) => if y == 0 and x > 0 and x < columns + 1 { 1pt + fg-color },
      `tags:`, ..range(columns).map(_ => `t`), $dots.c.h$,
      [], ..range(columns).map(_ => [1]), $dots.c.h$,
    )

    #let columns = 3
    #grid(
      rows: (1.3em, 1.3em),
      columns: (4em,) + range(columns).map(_ => 8em) + (2em,),
      row-gutter: (0em, 1em, 0em, 1em),
      stroke: (x, y) => if y == 0 and x > 0 and x < columns + 1 { 1pt + fg-color },
      `data:`, ..range(columns).map(_ => `data`), $dots.c.h$,
      [], ..range(columns).map(_ => [8]), $dots.c.h$,
    )
  ])

  Как всё классно укладывается в кеш и векторизуется. Посмотрим
]

#slide[
  = Альтернативные бенчмарки (1)

  #benchmark(
    [На 100.000 выражений со средней глубиной 12.6 (129-663МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.153, 0.750, 0.261, 0.014, 0.201, 0.704),
  )
]

#slide[
  = Альтернативные бенчмарки (2)

  #benchmark(
    [На 5.000.000 выражений глубины 3 (264-1300МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.828, 1.371, 0.521, 0.025, 0.360, 1.224),
  )
]

#slide[
  = Альтернативные бенчмарки (3)

  #benchmark(
    [На 16 выражениях глубины 27 (194-1003МБ)],
    ("GPA", "Arena", "AoS", "SoA", "AoS+", "Arena+"),
    (red, green, blue, purple, orange, blood),
    (1.548, 1.114, 0.368, 0.02, 0.257, 0.986),
  )
]

#slide[
  = Takeaways

  - Плотно укладывать данные --- круто
  - Арены --- круто
  - Доверяй, но проверяй
  - Следите за своим I/O
  #only(2)[
    - ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ ЗАМЕРЯЙТЕ
  ]
]

#slide[
  = Further reading

  #let qr-width = 10cm

  #columns(2)[
    #figure(
      caption: [Andrew Kelley: A Practical Guide to Applying Data Oriented Design (DoD)],
      qr("https://youtu.be/IroPQ150F6c", qr-width),
    )
    #colbreak()
    #figure(
      caption: [CppCon 2014: Mike Acton "Data-Oriented Design and C++"],
      qr("https://youtu.be/rX0ItVEVjHc", qr-width),
    )
  ]
]

#slide[
  = Материалы

  #figure(
    caption: [GitHub-репозиторий доклада],
    qr("https://github.com/bo1led-owl/.text-dod", 10cm),
  )
]
