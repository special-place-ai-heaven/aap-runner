using System;
using System.Linq;

namespace Legacy
{
    internal static class Program
    {
        private static void Main()
        {
            int sum = Enumerable.Range(1, 4).Sum();
            Console.WriteLine("hello from netfx sum=" + sum + " clr=" + Environment.Version.Major);
        }
    }
}
