package main

import "testing"

func TestSum(t *testing.T) {
	if sum(4) != 10 {
		t.Fatal("sum(4) != 10")
	}
}
