using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

// Observes desktop changes and closes matched native consent windows. Native
// Allow is invoked by the UIA adapter; this helper never activates/restores windows.
public static class NightlyDesktop {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint message, IntPtr w, IntPtr l);
    public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr Hwnd; public uint Message; public UIntPtr WParam; public IntPtr LParam; public uint Time; public int X, Y; public uint Private; }
    delegate void WinEvent(IntPtr hook, uint kind, IntPtr hwnd, int objectId, int childId, uint thread, uint time);
    public struct FocusEvent { public long Window; public uint Process; }
    static readonly ConcurrentQueue<FocusEvent> Events = new ConcurrentQueue<FocusEvent>();
    static readonly ManualResetEventSlim Ready = new ManualResetEventSlim();
    static Thread watcher;
    static uint watcherId;
    static IntPtr hookHandle;
    static WinEvent callback;
    public static void Start() {
        callback = (hook, kind, hwnd, objectId, childId, thread, time) => {
            uint process;
            GetWindowThreadProcessId(hwnd, out process);
            Events.Enqueue(new FocusEvent { Window = hwnd.ToInt64(), Process = process });
        };
        watcher = new Thread(() => {
            watcherId = GetCurrentThreadId();
            hookHandle = SetWinEventHook(3, 3, IntPtr.Zero, callback, 0, 0, 0);
            Ready.Set();
            if (hookHandle == IntPtr.Zero) return;
            Msg msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {}
            UnhookWinEvent(hookHandle);
        });
        watcher.IsBackground = true;
        watcher.Start();
        if (!Ready.Wait(2000) || hookHandle == IntPtr.Zero) throw new Exception("F_OBSERVER_UNAVAILABLE");
    }
    public static FocusEvent[] ForegroundEvents() { return Events.ToArray(); }
    public static void CloseResetConsent(IntPtr hwnd) {
        if (!PostMessage(hwnd, 0x10, IntPtr.Zero, IntPtr.Zero)) throw new Exception("F_CONSENT_CLOSE_FAILED");
    }
    public static void Stop() {
        if (watcher != null) {
            PostThreadMessage(watcherId, 0x12, IntPtr.Zero, IntPtr.Zero);
            watcher.Join(2000);
        }
    }
}
