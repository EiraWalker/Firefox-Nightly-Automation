using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class NightlyLauncherNative {
    delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, uint thread);
    [DllImport("kernel32.dll")] static extern uint GetProcessIdOfThread(IntPtr thread);
    [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] internal static extern int GetThreadPriority(IntPtr thread);
    [DllImport("ntdll.dll")] internal static extern int NtQueryInformationThread(IntPtr thread, int information, out uint value, uint size, IntPtr length);
    [DllImport("ntdll.dll")] internal static extern int NtSetInformationThread(IntPtr thread, int information, ref uint value, uint size);

    public static string[] Arguments(string command) {
        int count;
        IntPtr memory = CommandLineToArgvW(command, out count);
        if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            var arguments = new string[count];
            for (int i = 0; i < count; i++) arguments[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            return arguments;
        } finally { LocalFree(memory); }
    }

    // WM_NULL probes the browser's own message pump. A profile-in-use dialog or
    // merely having a process ID must not count as a browser ready for input.
    public static long[] BrowserWindow(int[] processes, bool requireResponsive) {
        var allowed = new HashSet<int>(processes);
        long[] found = new long[0];
        EnumWindows((window, parameter) => {
            uint process;
            GetWindowThreadProcessId(window, out process);
            if (!allowed.Contains((int)process)) return true;
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "MozillaWindowClass") return true;
            IntPtr result;
            if (requireResponsive && SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 2, 250, out result) == IntPtr.Zero) return true;
            found = new long[] { process, window.ToInt64() };
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static long[] ResponsiveBrowser(int[] processes) { return BrowserWindow(processes, true); }

    public static bool MatchesProcess(int processId, long startUtcTicks) {
        try {
            using (var process = Process.GetProcessById(processId)) {
                return !process.HasExited && process.StartTime.ToUniversalTime().Ticks == startUtcTicks;
            }
        } catch (ArgumentException) { return false; }
    }

    static string ReadHangString(BinaryReader reader) {
        uint length = reader.ReadUInt32();
        if (length > 65536 || length > reader.BaseStream.Length - reader.BaseStream.Position) throw new InvalidDataException();
        return Encoding.UTF8.GetString(reader.ReadBytes((int)length));
    }

    // Firefox persists this format after an 8-second main-thread stall. Require
    // both the startup/main-process header and the exact cache read marker;
    // generic hangs are not permission to change scheduling.
    public static bool IsStartupCacheHang(byte[] data) {
        if (data.Length < 40 || data.Length > 1024 * 1024) return false;
        try {
            using (var reader = new BinaryReader(new MemoryStream(data))) {
                if (Encoding.ASCII.GetString(reader.ReadBytes(16)) != "permahangsavev1\0") return false;
                if (reader.ReadUInt32() < 8192 || ReadHangString(reader) != "Gecko") return false;
                ReadHangString(reader); // Runnable name.
                if (ReadHangString(reader) != "default") return false;
            }
            return Encoding.UTF8.GetString(data).Contains("StartupCache::GetBuffer");
        } catch (IOException) { return false; }
    }

    public static NightlyIoRecovery BeginCacheIoRecovery(int processId, long startUtcTicks) {
        var recovery = new NightlyIoRecovery();
        try {
            using (var process = Process.GetProcessById(processId)) {
                // Holding a process handle also keeps this process identity alive
                // while opening its threads; never act on a recycled PID/TID.
                IntPtr processHandle = process.Handle;
                if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != startUtcTicks) return recovery;
                foreach (ProcessThread thread in process.Threads) {
                    IntPtr handle = OpenThread(0x60, false, (uint)thread.Id); // Query and set information only.
                    if (handle == IntPtr.Zero) continue;
                    uint priority;
                    uint normal = 2;
                    // -4 is the Win32 THREAD_MODE_BACKGROUND_BEGIN relative priority.
                    // It identifies the mode used by Gecko's nsAutoLowPriorityIO.
                    bool changed = GetProcessIdOfThread(handle) == (uint)processId &&
                        GetThreadPriority(handle) == -4 &&
                        NtQueryInformationThread(handle, 22, out priority, 4, IntPtr.Zero) >= 0 && priority == 0 &&
                        NtSetInformationThread(handle, 22, ref normal, 4) >= 0;
                    if (changed) recovery.Add(handle, thread.Id);
                    else CloseHandle(handle);
                }
            }
            return recovery;
        } catch {
            recovery.Dispose();
            throw;
        }
    }

    public static bool Activate(long handle) {
        var window = new IntPtr(handle);
        if (!IsWindowVisible(window)) return false;
        if (IsIconic(window)) ShowWindowAsync(window, 9);
        return SetForegroundWindow(window);
    }
}

// Only the I/O priority changes. CPU, memory, processes and files are untouched.
// Restore unrelated threads which are still in background mode. The cache
// writer normally leaves that mode itself as soon as its write completes.
public sealed class NightlyIoRecovery : IDisposable {
    readonly List<IntPtr> handles = new List<IntPtr>();
    public List<int> Threads { get; private set; } = new List<int>();
    internal void Add(IntPtr handle, int id) { handles.Add(handle); Threads.Add(id); }
    public void Dispose() {
        foreach (IntPtr handle in handles) {
            uint current;
            uint background = 0;
            if (NightlyLauncherNative.GetThreadPriority(handle) == -4 &&
                NightlyLauncherNative.NtQueryInformationThread(handle, 22, out current, 4, IntPtr.Zero) >= 0 && current == 2) {
                NightlyLauncherNative.NtSetInformationThread(handle, 22, ref background, 4);
            }
            NightlyLauncherNative.CloseHandle(handle);
        }
        handles.Clear();
    }
}
