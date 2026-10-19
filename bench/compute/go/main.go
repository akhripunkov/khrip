// Вычислительные задачи: те же, что в khrip/compute.kh.
package main

import (
	"fmt"
	"os"
)

func fib(n int64) int64 {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func sieve(n int) int {
	composite := make([]bool, n+1)
	count := 0
	for i := 2; i <= n; i++ {
		if !composite[i] {
			count++
			for j := i * i; j <= n; j += i {
				composite[j] = true
			}
		}
	}
	return count
}

func main() {
	switch os.Args[1] {
	case "fib":
		fmt.Println(fib(38))
	case "sieve":
		fmt.Println(sieve(20000000))
	}
}
