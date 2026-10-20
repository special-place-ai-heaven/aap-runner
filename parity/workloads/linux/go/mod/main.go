package main

/*
static int native_mul(int a, int b) { return a * b; }
*/
import "C"

import "fmt"

func sum(n int) int {
	s := 0
	for i := 1; i <= n; i++ {
		s += i
	}
	return s
}

func main() {
	fmt.Printf("hello from go sum=%d cgo_mul=%d\n", sum(4), int(C.native_mul(6, 7)))
}
