/* Windows x64 console program with no C runtime and no SDK: three kernel32 functions declared here and imported
   through an import library made from kernel32.def. Built on Linux with clang and lld-link (/Brepro, so the bytes are
   reproducible); it only proves anything about Windows once a Windows machine has run it. */
typedef void *HANDLE;
typedef unsigned long DWORD;
typedef int BOOL;

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *written, void *overlapped);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int code);

void __stdcall parity_entry(void)
{
    static const char msg[] = "hello from xwin freestanding\r\n";
    DWORD written = 0;
    WriteFile(GetStdHandle((DWORD)-11), msg, sizeof msg - 1, &written, 0);
    ExitProcess(written == sizeof msg - 1 ? 42 : 1);
}
