// Отладочная вставка для замеров памяти (bench/mem/attr.sh): файл кладётся в
// копию Go-решения из eval/solutions, в сами решения не входит. По SIGUSR1
// печатает в stderr runtime.MemStats до и после принудительной сборки:
// heap_alloc после сборки — живая куча, сравнимая с живыми данными store Khrip.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"syscall"
)

func init() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	go func() {
		for range ch {
			var m runtime.MemStats
			runtime.ReadMemStats(&m)
			print1("before", &m)
			runtime.GC()
			runtime.ReadMemStats(&m)
			print1("after-gc", &m)
		}
	}()
}

func print1(when string, m *runtime.MemStats) {
	fmt.Fprintf(os.Stderr, "memstats %s heap_alloc=%d heap_inuse=%d heap_idle=%d heap_released=%d heap_sys=%d heap_objects=%d stack_inuse=%d stack_sys=%d mspan_inuse=%d mcache_inuse=%d gc_sys=%d other_sys=%d buck_hash_sys=%d sys=%d num_gc=%d next_gc=%d\n",
		when, m.HeapAlloc, m.HeapInuse, m.HeapIdle, m.HeapReleased, m.HeapSys, m.HeapObjects, m.StackInuse, m.StackSys,
		m.MSpanInuse, m.MCacheInuse, m.GCSys, m.OtherSys, m.BuckHashSys, m.Sys, m.NumGC, m.NextGC)
}
