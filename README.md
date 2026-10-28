# properly cooking with data-oriented design

## Структура репозитория

- `assembler.zig` - ассемблер программ, вызывается через `zig build assemble -- IN OUT`
- `dod.zig` - data-oriented реализация, вызывается через `zig build run-dod`, ожидает бинарный ввод в stdin
- `oop.zig` - "object"-oriented реализация, вызывается через `zig build run-oop`, ожидает бинарный ввод в stdin. Содержит ручки `use_arena_for_expressions` и `use_arena_for_names`, чтобы управлять использованием арен для аллокаций
- `gen.go` - генератор программ на исходном языке. Параметры указываются в самом `gen.go`, вызывается через `go run gen.go`, вывод в stdout
- `example` - пример кода на исходном языке
- `pres.pdf` - презентация к докладу
- `pres/` - исходный код презентации

## Запуск бенчмарка

Для бенчмарка необходим `hyperfine`.

`zig build --release=fast bench` запустит бенчмарк реализаций на программе в файле `benchmark-input`. `benchmark-input` должен содержать исходный код. Команда его автоматически соберёт и передаст реализациям
