package main

import (
	"fmt"
	"math/rand"
	"time"
)

const N_COMMANDS int = 50_000
const MAX_NUMBER int = 1_000_000_000
const MAX_DEPTH int = 42

func main() {
	seed := time.Now().UnixNano()
	g := NewGenerator(seed)
	for range N_COMMANDS {
		g.genCommand()
	}
}

// expr := int | ident
//
//	| "+" expr expr | "-" expr expr | "*" expr expr | "/" expr expr
//	| "print" expr
//	| "=" ident expr
//
// stmt := expr ";"
type Generator struct {
	rng     *rand.Rand
	defined []string
	nameIdx int
}

func NewGenerator(seed int64) *Generator {
	return &Generator{rng: rand.New(rand.NewSource(seed))}
}

func (g *Generator) genCommand() {
	g.genExpr(g.rng.Intn(MAX_DEPTH))
	fmt.Println(";")
}

func (g *Generator) nextName() string {
	if g.nameIdx < 26 {
		name := string(rune('a' + g.nameIdx))
		g.nameIdx++
		return name
	}

	idx := g.nameIdx - 26
	letter := rune('a' + idx%26)
	num := idx/26 + 1
	g.nameIdx++
	return fmt.Sprintf("%c%d", letter, num)
}

func (g *Generator) pickVar() string {
	return g.defined[g.rng.Intn(len(g.defined))]
}

func (g *Generator) genLeaf() {
	if len(g.defined) > 0 && g.rng.Intn(2) == 0 {
		fmt.Printf("%s ", g.pickVar())
	} else {
		fmt.Printf("%d ", g.rng.Intn(MAX_NUMBER))
	}
}

func (g *Generator) genExpr(depth int) {
	if depth == 0 {
		g.genLeaf()
		return
	}

	roll := g.rng.Intn(6)
	switch roll {
	case 4:
		// assignment
		var name string
		var isNew = false
		if len(g.defined) > 0 && g.rng.Int() % 2 == 0{
			name = g.pickVar()
		} else {
			name = g.nextName()
			isNew = true
		}

		fmt.Print("= ")
		fmt.Printf("%s ", name)
		g.genExpr(g.rng.Intn(depth))

		if isNew {
			g.defined = append(g.defined, name)
		}
	case 5:
		// print
		fmt.Print("print ")
		g.genExpr(g.rng.Intn(depth))
	default: // 0..3
		// binary
		op := []rune{'+', '-', '*', '/'}[roll]
		fmt.Printf("%c ", op)
		g.genExpr(g.rng.Intn(depth))
		g.genExpr(g.rng.Intn(depth))
	}
}
