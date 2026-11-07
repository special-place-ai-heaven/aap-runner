// Handle-relative, no-follow directory deletion for parity-work cleanup.
// C# 5 only: Windows PowerShell 5.1 compiles this with the .NET Framework compiler.
//
// Guarantee. The registered path is resolved one component at a time from the
// volume root, each component opened relative to its already-open parent handle
// with FILE_OPEN_REPARSE_POINT (and OBJ_DONT_REPARSE below the volume root), and
// every opened component is checked for a reparse point. The final directory's
// volume serial and 128-bit file ID must equal the identity recorded at
// registration. Descendants are enumerated from the open parent handle and each
// child is opened relative to that handle, again without following reparse
// points, and checked on the opened handle itself; deletion is a disposition set
// on that same handle. A path is never re-resolved by name, so swapping any
// ancestor or descendant for a junction/symlink after the check cannot redirect
// an open or a delete outside the tree: the swap is either detected (HOLD) or
// irrelevant because we already hold the real object. Ancestors and the root are
// held open without FILE_SHARE_DELETE for the whole operation, so they cannot be
// renamed or deleted underneath us; directories inside the tree are held without
// FILE_SHARE_WRITE|DELETE.
//
// Residual limits. Objects that a concurrent actor moves INTO the tree before we
// open their parent are deleted as part of the tree (they are physically inside
// it; nothing outside is followed). Hard links: deleting our link removes only
// that name. On a filesystem without POSIX/ex dispositions we clear READONLY only
// when the file has a single link, otherwise HOLD.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ParityWork
{
    public class HoldException : Exception
    {
        public string Code;
        public string RelPath;
        public bool Retryable;
        public HoldException(string code, string relPath, string detail, bool retryable)
            : base(code + " at '" + relPath + "': " + detail)
        {
            Code = code; RelPath = relPath; Retryable = retryable;
        }
    }

    public static class SafeTree
    {
        const uint DELETE = 0x10000, SYNCHRONIZE = 0x100000;
        const uint FILE_LIST_DIRECTORY = 0x1, FILE_TRAVERSE = 0x20;
        const uint FILE_READ_ATTRIBUTES = 0x80, FILE_WRITE_ATTRIBUTES = 0x100;
        const uint SHARE_READ = 1, SHARE_WRITE = 2, SHARE_DELETE = 4;
        const uint FILE_OPEN = 1, FILE_CREATE = 2;
        const uint FILE_DIRECTORY_FILE = 0x1, FILE_SYNCHRONOUS_IO_NONALERT = 0x20;
        const uint FILE_NON_DIRECTORY_FILE = 0x40, FILE_READ_DATA = 0x1;
        const uint FILE_OPEN_REPARSE_POINT = 0x200000;
        const uint OBJ_CASE_INSENSITIVE = 0x40, OBJ_DONT_REPARSE = 0x1000;
        const uint ATTR_READONLY = 0x1, ATTR_DIRECTORY = 0x10, ATTR_REPARSE = 0x400;

        [StructLayout(LayoutKind.Sequential)]
        struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

        [StructLayout(LayoutKind.Sequential)]
        struct OBJECT_ATTRIBUTES
        {
            public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
            public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_STATUS_BLOCK { public IntPtr Status; public IntPtr Information; }

        [DllImport("ntdll.dll")]
        static extern int NtCreateFile(out IntPtr handle, uint access, ref OBJECT_ATTRIBUTES oa,
            out IO_STATUS_BLOCK iosb, IntPtr allocationSize, uint fileAttributes, uint share,
            uint disposition, uint options, IntPtr eaBuffer, uint eaLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int cls, IntPtr buf, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle h, int cls, IntPtr buf, uint size);

        struct Entry { public string Name; public uint Attributes; }

        // One directory of the explicit walk stack: its handle, relative path, entries and cursor.
        sealed class Frame
        {
            public SafeFileHandle Handle; public string Rel; public List<Entry> Entries; public int Next;
        }

        // Test seam: called with "preflight:<rel>" or "delete:<rel>" after an entry is
        // enumerated and before it is opened. Null in production.
        public static Action<string> TestHook;

        // ---- public API -------------------------------------------------------

        // Creates a new directory (FILE_CREATE: an existing object is never adopted) relative
        // to its parent, which is reached without following any reparse point, and returns the
        // identity read from the creating handle.
        public static string CreateDirectory(string path)
        {
            string p = path == null ? "" : path.TrimEnd('\\');
            int cut = p.LastIndexOf('\\');
            if (cut < 3) throw new HoldException("PATH", ".", "not a directory below a drive root", false);
            string name = p.Substring(cut + 1);
            if (name.Length == 0 || name.Length > 255 || name == "." || name == ".." || name.IndexOf(':') >= 0)
                throw new HoldException("PATH", name, "bad directory name", false);
            List<SafeFileHandle> chain = OpenChain(p.Substring(0, cut), false);
            try
            {
                using (SafeFileHandle h = Open(chain[chain.Count - 1], name, FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                    SHARE_READ | SHARE_WRITE | SHARE_DELETE, FILE_DIRECTORY_FILE, name, true, FILE_CREATE))
                    return Identity(h);
            }
            finally { CloseAll(chain); }
        }

        // "volumeserial:fileid" of an existing directory reached without following any reparse point.
        public static string GetIdentity(string path)
        {
            List<SafeFileHandle> chain = OpenChain(path, false);
            try { return Identity(chain[chain.Count - 1]); }
            finally { CloseAll(chain); }
        }

        // Deletes the directory at path and everything below it. Returns false when the
        // path is absent (nothing to do). Throws HoldException on any reparse point,
        // identity mismatch, non-empty root when requireEmpty, or I/O failure.
        public static bool DeleteTree(string path, string identity, bool requireEmpty)
        {
            List<SafeFileHandle> chain;
            try { chain = OpenChain(path, true); }
            catch (HoldException e) { if (e.Code == "NOT_FOUND" && e.RelPath == ".") return false; throw; }
            try
            {
                SafeFileHandle root = chain[chain.Count - 1];
                string actual = Identity(root);
                if (!string.Equals(actual, identity, StringComparison.OrdinalIgnoreCase))
                    throw new HoldException("IDENTITY", ".", "registered identity does not match the object at the path", false);
                if (requireEmpty)
                {
                    List<Entry> left = Enumerate(root, ".");
                    if (left.Count > 0)
                        throw new HoldException("NOT_EMPTY", left[0].Name, left.Count + " unregistered entr(y/ies) remain", false);
                }
                Walk(root, false);   // preflight: refuse before touching anything
                Walk(root, true);    // the qualified delete; re-checks every object it opens
                Dispose(root, ".");
                return true;
            }
            finally { CloseAll(chain); }
        }

        // Opens a regular file for reading through the same no-follow chain. HOLD when any
        // ancestor or the file itself is a reparse point, or the file has several links.
        public static System.IO.FileStream OpenFileNoFollow(string path)
        {
            int cut = path == null ? -1 : path.LastIndexOf('\\');
            if (cut < 3) throw new HoldException("PATH", ".", "not a file below a drive root", false);
            string name = path.Substring(cut + 1);
            if (name.Length == 0 || name.Length > 255 || name.IndexOf(':') >= 0)
                throw new HoldException("PATH", name, "bad file name", false);
            List<SafeFileHandle> chain = OpenChain(path.Substring(0, cut), false);
            try
            {
                SafeFileHandle h = Open(chain[chain.Count - 1], name, FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                    SHARE_READ, FILE_NON_DIRECTORY_FILE, name, true);
                try
                {
                    if ((AttrTag(h, name) & ATTR_REPARSE) != 0)
                        throw new HoldException("REPARSE", name, "asset source is a reparse point", false);
                    IntPtr buf = Marshal.AllocHGlobal(24);
                    try
                    {
                        if (!GetFileInformationByHandleEx(h, 1, buf, 24)) throw FromWin32(Marshal.GetLastWin32Error(), name);
                        if (Marshal.ReadInt32(buf, 16) != 1)
                            throw new HoldException("HARDLINK", name, "asset source has several links", false);
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                    return new System.IO.FileStream(h, System.IO.FileAccess.Read);
                }
                catch { h.Dispose(); throw; }
            }
            finally { CloseAll(chain); }
        }

        // ---- internals --------------------------------------------------------

        static List<SafeFileHandle> OpenChain(string path, bool forDelete)
        {
            if (path == null || path.Length < 4 || path[1] != ':' || path[2] != '\\' || !char.IsLetter(path[0]))
                throw new HoldException("PATH", ".", "not an absolute drive path", false);
            string[] parts = path.Substring(3).TrimEnd('\\').Split('\\');
            List<SafeFileHandle> chain = new List<SafeFileHandle>();
            try
            {
                chain.Add(Open(null, "\\??\\" + path.Substring(0, 3),
                    FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                    SHARE_READ | SHARE_WRITE | SHARE_DELETE, FILE_DIRECTORY_FILE, "<volume>", true));
                for (int i = 0; i < parts.Length; i++)
                {
                    string p = parts[i];
                    if (p.Length == 0 || p.Length > 255 || p == "." || p == ".." || p.IndexOf(':') >= 0)
                        throw new HoldException("PATH", p, "bad path component", false);
                    bool last = i == parts.Length - 1;
                    string rel = last ? "." : "ancestor:" + p;
                    uint access = FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
                    uint share = SHARE_READ | SHARE_WRITE;
                    if (last && forDelete) { access |= DELETE | FILE_WRITE_ATTRIBUTES; share = SHARE_READ; }
                    if (!forDelete) share |= SHARE_DELETE;
                    SafeFileHandle h = Open(chain[chain.Count - 1], p, access, share, FILE_DIRECTORY_FILE, rel, true);
                    chain.Add(h);
                    if ((AttrTag(h, rel) & ATTR_REPARSE) != 0)
                        throw new HoldException("REPARSE", rel, "reparse point in registered path", false);
                }
                return chain;
            }
            catch { CloseAll(chain); throw; }
        }

        // Depth-first, post-order, with an explicit stack (no recursion: depth is bounded
        // only by the path length, not by the thread stack). Every open directory stays
        // open until its children are done, exactly as in a recursive walk.
        static void Walk(SafeFileHandle root, bool delete)
        {
            string phase = delete ? "delete:" : "preflight:";
            Stack<Frame> stack = new Stack<Frame>();
            Frame top = new Frame();
            top.Handle = root; top.Rel = ""; top.Entries = Enumerate(root, ".");
            stack.Push(top);
            try
            {
                while (stack.Count > 0)
                {
                    Frame f = stack.Peek();
                    if (f.Next >= f.Entries.Count)
                    {
                        stack.Pop();
                        if (f.Handle != root)
                        {
                            try { if (delete) Dispose(f.Handle, f.Rel); }
                            finally { f.Handle.Dispose(); }
                        }
                        continue;
                    }
                    Entry e = f.Entries[f.Next++];
                    string crel = f.Rel == "" ? e.Name : f.Rel + "\\" + e.Name;
                    if (e.Name.IndexOf(':') >= 0)
                        throw new HoldException("ADS", crel, "stream name", false);
                    if ((e.Attributes & ATTR_REPARSE) != 0)
                        throw new HoldException("REPARSE", crel, "reparse point in tree", false);
                    bool isDir = (e.Attributes & ATTR_DIRECTORY) != 0;
                    uint access = FILE_READ_ATTRIBUTES | SYNCHRONIZE;
                    if (isDir) access |= FILE_LIST_DIRECTORY | FILE_TRAVERSE;
                    if (delete) access |= DELETE | FILE_WRITE_ATTRIBUTES;
                    uint share = isDir ? SHARE_READ : SHARE_READ | SHARE_WRITE;
                    if (!delete) share = SHARE_READ | SHARE_WRITE | SHARE_DELETE;
                    Action<string> hook = TestHook;
                    if (hook != null) hook(phase + crel);
                    SafeFileHandle h;
                    try { h = Open(f.Handle, e.Name, access, share, isDir ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE, crel, false, FILE_OPEN); }
                    catch (HoldException ex) { if (ex.Code == "NOT_FOUND") continue; throw; }
                    bool pushed = false;
                    try
                    {
                        uint attrs = AttrTag(h, crel);
                        if ((attrs & ATTR_REPARSE) != 0)
                            throw new HoldException("REPARSE", crel, "object became a reparse point", false);
                        if (((attrs & ATTR_DIRECTORY) != 0) != isDir)
                            throw new HoldException("CHANGED", crel, "object type changed during walk", false);
                        if (isDir)
                        {
                            Frame c = new Frame();
                            c.Handle = h; c.Rel = crel; c.Entries = Enumerate(h, crel);
                            stack.Push(c);
                            pushed = true;
                        }
                        else if (delete) Dispose(h, crel);
                    }
                    finally { if (!pushed) h.Dispose(); }
                }
            }
            finally
            {
                while (stack.Count > 0) { Frame f = stack.Pop(); if (f.Handle != root) f.Handle.Dispose(); }
            }
        }

        static SafeFileHandle Open(SafeFileHandle parent, string name, uint access, uint share,
            uint options, string rel, bool caseInsensitive)
        {
            return Open(parent, name, access, share, options, rel, caseInsensitive, FILE_OPEN);
        }

        static SafeFileHandle Open(SafeFileHandle parent, string name, uint access, uint share,
            uint options, string rel, bool caseInsensitive, uint disposition)
        {
            IntPtr nameBuf = Marshal.StringToHGlobalUni(name);
            IntPtr us = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
            try
            {
                UNICODE_STRING u;
                u.Length = (ushort)(name.Length * 2);
                u.MaximumLength = (ushort)(name.Length * 2 + 2);
                u.Buffer = nameBuf;
                Marshal.StructureToPtr(u, us, false);
                OBJECT_ATTRIBUTES oa = new OBJECT_ATTRIBUTES();
                oa.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));
                oa.RootDirectory = parent == null ? IntPtr.Zero : parent.DangerousGetHandle();
                oa.ObjectName = us;
                oa.Attributes = (caseInsensitive ? OBJ_CASE_INSENSITIVE : 0) | (parent == null ? 0 : OBJ_DONT_REPARSE);
                IntPtr h;
                IO_STATUS_BLOCK iosb;
                int st = NtCreateFile(out h, access, ref oa, out iosb, IntPtr.Zero, 0, share, disposition,
                    options | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
                    IntPtr.Zero, 0);
                GC.KeepAlive(parent);
                if (st < 0) throw FromStatus((uint)st, rel);
                return new SafeFileHandle(h, true);
            }
            finally { Marshal.FreeHGlobal(us); Marshal.FreeHGlobal(nameBuf); }
        }

        static List<Entry> Enumerate(SafeFileHandle dir, string rel)
        {
            List<Entry> list = new List<Entry>();
            const uint size = 64 * 1024;
            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try
            {
                int cls = 11; // FileIdBothDirectoryRestartInfo, then FileIdBothDirectoryInfo
                while (true)
                {
                    if (!GetFileInformationByHandleEx(dir, cls, buf, size))
                    {
                        int err = Marshal.GetLastWin32Error();
                        if (err == 18) break; // ERROR_NO_MORE_FILES
                        throw FromWin32(err, rel);
                    }
                    cls = 10;
                    int off = 0;
                    while (true)
                    {
                        int next = Marshal.ReadInt32(buf, off);
                        Entry e;
                        e.Attributes = (uint)Marshal.ReadInt32(buf, off + 56);
                        int nameLen = Marshal.ReadInt32(buf, off + 60);
                        e.Name = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + off + 104), nameLen / 2);
                        if (e.Name != "." && e.Name != "..") list.Add(e);
                        if (next == 0) break;
                        off += next;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return list;
        }

        static uint AttrTag(SafeFileHandle h, string rel)
        {
            IntPtr buf = Marshal.AllocHGlobal(8);
            try
            {
                if (!GetFileInformationByHandleEx(h, 9, buf, 8)) throw FromWin32(Marshal.GetLastWin32Error(), rel);
                return (uint)Marshal.ReadInt32(buf, 0);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        static string Identity(SafeFileHandle h)
        {
            IntPtr buf = Marshal.AllocHGlobal(24);
            try
            {
                if (!GetFileInformationByHandleEx(h, 18, buf, 24)) throw FromWin32(Marshal.GetLastWin32Error(), ".");
                byte[] b = new byte[24];
                Marshal.Copy(buf, b, 0, 24);
                return BitConverter.ToUInt64(b, 0).ToString("x16") + ":" + BitConverter.ToString(b, 8, 16).Replace("-", "").ToLowerInvariant();
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        static void Dispose(SafeFileHandle h, string rel)
        {
            IntPtr buf = Marshal.AllocHGlobal(40);
            try
            {
                // FileDispositionInfoEx: DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
                Marshal.WriteInt32(buf, 0, 0x1 | 0x2 | 0x10);
                if (SetFileInformationByHandle(h, 21, buf, 4)) return;
                int err = Marshal.GetLastWin32Error();
                if (err != 87 && err != 50 && err != 1) throw FromWin32(err, rel);

                // Fallback: classic disposition; clear READONLY only on a single-link file.
                if (!GetFileInformationByHandleEx(h, 0, buf, 40)) throw FromWin32(Marshal.GetLastWin32Error(), rel);
                uint attrs = (uint)Marshal.ReadInt32(buf, 32);
                if ((attrs & ATTR_READONLY) != 0)
                {
                    if (!GetFileInformationByHandleEx(h, 1, buf, 24)) throw FromWin32(Marshal.GetLastWin32Error(), rel);
                    if (Marshal.ReadInt32(buf, 16) != 1)
                        throw new HoldException("HARDLINK", rel, "read-only file with several links", false);
                    for (int i = 0; i < 32; i += 8) Marshal.WriteInt64(buf, i, 0);
                    Marshal.WriteInt32(buf, 32, (int)(attrs & ~ATTR_READONLY) == 0 ? 0x80 : (int)(attrs & ~ATTR_READONLY));
                    if (!SetFileInformationByHandle(h, 0, buf, 40)) throw FromWin32(Marshal.GetLastWin32Error(), rel);
                }
                Marshal.WriteByte(buf, 0, 1);
                if (!SetFileInformationByHandle(h, 4, buf, 1)) throw FromWin32(Marshal.GetLastWin32Error(), rel);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        static void CloseAll(List<SafeFileHandle> chain)
        {
            for (int i = chain.Count - 1; i >= 0; i--) chain[i].Dispose();
        }

        static HoldException FromStatus(uint st, string rel)
        {
            switch (st)
            {
                case 0xC0000034: case 0xC000003A:
                    return new HoldException("NOT_FOUND", rel, "not found", false);
                case 0xC0000035:
                    return new HoldException("EXISTS", rel, "already exists; an existing object is never adopted", false);
                case 0xC0000043: case 0xC0000056: case 0xC0000121: case 0xC0000101:
                    return new HoldException("SHARING", rel, "in use (NTSTATUS 0x" + st.ToString("X8") + ")", true);
                case 0xC000050B: case 0xC0000280:
                    return new HoldException("REPARSE", rel, "reparse point encountered", false);
                case 0xC0000103: case 0xC00000BA:
                    return new HoldException("CHANGED", rel, "object type changed", false);
                default:
                    return new HoldException("IO", rel, "NTSTATUS 0x" + st.ToString("X8"), false);
            }
        }

        static HoldException FromWin32(int err, string rel)
        {
            if (err == 32 || err == 145 || err == 303)
                return new HoldException("SHARING", rel, "in use (Win32 " + err + ")", true);
            if (err == 2 || err == 3)
                return new HoldException("NOT_FOUND", rel, "not found", false);
            return new HoldException("IO", rel, "Win32 " + err, false);
        }
    }

    // One process handle: identity (creation time, image path) is read from, and any
    // termination goes through, the same handle, so a reused PID cannot be hit.
    public sealed class OwnedProcess : IDisposable
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetProcessTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, System.Text.StringBuilder buf, ref int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr h, uint code);
        [DllImport("kernel32.dll")]
        static extern uint WaitForSingleObject(IntPtr h, uint ms);

        IntPtr h;
        public readonly string StartTicks;
        public readonly string ImagePath;   // null once the process has exited

        // Null when no process has this id; HOLD when it exists but cannot be inspected.
        public static OwnedProcess Open(int pid, bool terminate)
        {
            IntPtr h = OpenProcess(0x1000 | 0x100000 | (terminate ? 0x1u : 0u), false, pid);
            if (h == IntPtr.Zero)
            {
                int err = Marshal.GetLastWin32Error();
                if (err == 87) return null;
                throw new HoldException("PROCESS", pid.ToString(), "cannot open process (Win32 " + err + ")", false);
            }
            try { return new OwnedProcess(h, pid); }
            catch { CloseHandle(h); throw; }
        }

        OwnedProcess(IntPtr handle, int pid)
        {
            h = handle;
            long c, e, k, u;
            if (!GetProcessTimes(h, out c, out e, out k, out u))
                throw new HoldException("PROCESS", pid.ToString(), "cannot read start time (Win32 " + Marshal.GetLastWin32Error() + ")", false);
            if (c <= 0)
                throw new HoldException("PROCESS", pid.ToString(), "start time unreadable (zero)", false);
            StartTicks = DateTime.FromFileTimeUtc(c).Ticks.ToString();
            if (HasExited) return;
            System.Text.StringBuilder sb = new System.Text.StringBuilder(1024);
            int n = sb.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref n))
                throw new HoldException("PROCESS", pid.ToString(), "cannot read image path (Win32 " + Marshal.GetLastWin32Error() + ")", false);
            ImagePath = sb.ToString(0, n);
        }

        [DllImport("ntdll.dll")]
        static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr info, int len, out int ret);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);

        // Current directory of another process, read from its PEB (64-bit host only:
        // PEB.ProcessParameters at 0x20, CurrentDirectory.DosPath at 0x38). Null when it
        // cannot be read; such a process also cannot be inspected or killed by this actor,
        // and its open directory handle makes any deletion of that directory a HOLD.
        public static string GetCurrentDirectory(int pid)
        {
            if (IntPtr.Size != 8) return null;
            IntPtr ph = OpenProcess(0x1000 | 0x10, false, pid);   // QUERY_LIMITED_INFORMATION | VM_READ
            if (ph == IntPtr.Zero) return null;
            IntPtr pbi = Marshal.AllocHGlobal(48);
            try
            {
                int ret;
                if (NtQueryInformationProcess(ph, 0, pbi, 48, out ret) < 0) return null;
                IntPtr peb = Marshal.ReadIntPtr(pbi, 8);
                if (peb == IntPtr.Zero) return null;
                byte[] pp = ReadMem(ph, new IntPtr(peb.ToInt64() + 0x20), 8);
                if (pp == null) return null;
                byte[] us = ReadMem(ph, new IntPtr(BitConverter.ToInt64(pp, 0) + 0x38), 16);
                if (us == null) return null;
                int len = BitConverter.ToUInt16(us, 0);
                long buf = BitConverter.ToInt64(us, 8);
                if (len == 0 || buf == 0) return null;
                byte[] s = ReadMem(ph, new IntPtr(buf), len);
                return s == null ? null : System.Text.Encoding.Unicode.GetString(s);
            }
            finally { Marshal.FreeHGlobal(pbi); CloseHandle(ph); }
        }

        static byte[] ReadMem(IntPtr ph, IntPtr addr, int n)
        {
            byte[] b = new byte[n];
            IntPtr got;
            return ReadProcessMemory(ph, addr, b, new IntPtr(n), out got) && got.ToInt64() == n ? b : null;
        }

        public bool HasExited { get { return WaitForSingleObject(h, 0) == 0; } }

        public bool Terminate(int waitMs)
        {
            TerminateProcess(h, 1);
            return WaitForSingleObject(h, (uint)waitMs) == 0;
        }

        public void Dispose()
        {
            if (h != IntPtr.Zero) { CloseHandle(h); h = IntPtr.Zero; }
        }
    }
}
