using System;
using System.Linq;
using System.Runtime.InteropServices;

var sum = Enumerable.Range(1, 4).Sum();
Console.WriteLine($"hello from dotnet sum={sum} x64={RuntimeInformation.ProcessArchitecture == Architecture.X64} windows={OperatingSystem.IsWindows()}");
