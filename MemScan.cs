using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class MemScan
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MBI
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MBI mbi, IntPtr len);

    const int PROCESS_QUERY_INFORMATION = 0x0400;
    const int PROCESS_VM_READ = 0x0010;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_PRIVATE = 0x20000;
    const uint PAGE_NOACCESS = 0x01;
    const uint PAGE_GUARD = 0x100;

    static uint BE32(byte[] b, int o)
    {
        return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3];
    }

    static string FourCC(byte[] b, int o)
    {
        return "" + (char)b[o] + (char)b[o + 1] + (char)b[o + 2] + (char)b[o + 3];
    }

    // 合法的头：ftyp 之后最多再跨 3 个 box 就撞上 moov
    // （有的片子是 ftyp + free + moov 或 ftyp + uuid + moov，只认紧挨着的那种会漏掉整条视频）
    static bool MoovFollows(byte[] buf, int p)
    {
        for (int hop = 0; hop < 4; hop++)
        {
            if (p + 8 > buf.Length) return false;
            uint sz = BE32(buf, p);
            if (sz < 8 || sz > 32u * 1024 * 1024) return false;
            string t = FourCC(buf, p + 4);
            if (t == "moov") return true;
            if (t != "free" && t != "wide" && t != "uuid" && t != "skip" && t != "styp" && t != "sidx") return false;
            p += (int)sz;
        }
        return false;
    }

    // 在微信进程里找「解密后的 MP4 头」
    public static List<long> Scan(int pid, int maxResults)
    {
        var found = new List<long>();
        IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (h == IntPtr.Zero) { found.Add(-1); return found; }

        long addr = 0x10000;
        long max = 0x7FFFFFFF0000;
        MBI mbi;
        while (addr < max && found.Count < maxResults)
        {
            IntPtr q = VirtualQueryEx(h, (IntPtr)addr, out mbi, (IntPtr)Marshal.SizeOf(typeof(MBI)));
            if (q == IntPtr.Zero) break;
            long size = (long)mbi.RegionSize;
            if (size <= 0) break;

            bool ok = mbi.State == MEM_COMMIT && mbi.Type == MEM_PRIVATE
                      && (mbi.Protect & PAGE_NOACCESS) == 0 && (mbi.Protect & PAGE_GUARD) == 0
                      && size <= 64L * 1024 * 1024;
            if (ok)
            {
                byte[] buf = new byte[size];
                IntPtr read;
                if (ReadProcessMemory(h, (IntPtr)addr, buf, (IntPtr)size, out read) && (long)read == size)
                {
                    for (int i = 0; i + 64 < buf.Length; i++)
                    {
                        if (buf[i + 4] != (byte)'f' || buf[i + 5] != (byte)'t' || buf[i + 6] != (byte)'y' || buf[i + 7] != (byte)'p') continue;
                        uint s1 = BE32(buf, i);
                        if (s1 < 16 || s1 > 512) continue;
                        int mo = i + (int)s1;
                        if (mo + 8 >= buf.Length) continue;
                        if (!MoovFollows(buf, mo)) continue;
                        found.Add((long)addr + i);
                        if (found.Count >= maxResults) break;
                    }
                }
            }
            addr += size;
        }
        CloseHandle(h);
        return found;
    }

    public static bool Dump(int pid, long address, int length, string path)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (h == IntPtr.Zero) return false;
        byte[] buf = new byte[length];
        IntPtr read;
        bool ok = ReadProcessMemory(h, (IntPtr)address, buf, (IntPtr)length, out read);
        CloseHandle(h);
        if (!ok) return false;
        System.IO.File.WriteAllBytes(path, buf);
        return true;
    }
}
