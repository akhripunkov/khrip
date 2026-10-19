// Вычислительные задачи: те же, что в khrip/compute.kh.
static long Fib(long n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);

static int Sieve(int n)
{
    var composite = new bool[n + 1];
    var count = 0;
    for (var i = 2; i <= n; i++)
    {
        if (composite[i]) continue;
        count++;
        for (long j = (long)i * i; j <= n; j += i) composite[j] = true;
    }
    return count;
}

switch (args[0])
{
    case "fib": Console.WriteLine(Fib(38)); break;
    case "sieve": Console.WriteLine(Sieve(20000000)); break;
}
