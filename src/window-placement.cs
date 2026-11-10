using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

// Only call for a freshly verified native HWND inside the caller's authorized
// service-start interval. IsWindow is not an ownership/lifetime guarantee.
public static class NightlyWindowPlacement
{
    public sealed class Snapshot
    {
        // Raw rcNormalPosition (workspace coordinates for ordinary top-level
        // windows), not GetWindowRect/screen coordinates. Never reposition it.
        public int[] NormalBounds;
        public string RestoredState;
        public bool Minimized;
        public uint ShowCommand, Flags;
    }

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowPlacement(IntPtr hwnd, ref WindowPlacement placement);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr hwnd, int command);

    // true means the asynchronous request started, NOT that the resulting
    // window state was observed. false means already in the requested state.
    // The caller must poll Read and recheck its PID/generation/lifecycle guards.
    public static bool Restore(IntPtr hwnd)
    {
        return Restore(hwnd, null);
    }

    public static bool Restore(IntPtr hwnd, Action finalGuard)
    {
        // SW_RESTORE on a non-minimized maximized window would unmaximize it.
        if (!Read(hwnd).Minimized) return false;
        return Queue(hwnd, 9, finalGuard); // SW_RESTORE: authorized short-lived activation.
    }

    public static bool MinimizeNoActivate(IntPtr hwnd)
    {
        return MinimizeNoActivate(hwnd, null);
    }

    public static bool MinimizeNoActivate(IntPtr hwnd, Action finalGuard)
    {
        if (Read(hwnd).Minimized) return false;
        return Queue(hwnd, 7, finalGuard); // SW_SHOWMINNOACTIVE: does not activate this HWND.
    }

    private static bool Queue(IntPtr hwnd, int command, Action finalGuard)
    {
        ValidateWindow(hwnd);
        // Never rewrite WINDOWPLACEMENT flags or coordinates. In particular,
        // retain Windows' maximized-before-minimizing restoration bookkeeping.
        // Read/IsWindow may themselves race with HWND reuse. The caller's exact
        // PID/generation/cookie guard must be LAST; no native read follows it.
        // This narrows the boundary, not an atomic OS lifetime guarantee.
        if (finalGuard != null) finalGuard();
        if (!ShowWindowAsync(hwnd, command)) throw NativeFailure("ShowWindowAsync");
        return true;
    }

    private static void ValidateWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd))
            throw new Win32Exception(1400, "Invalid native window handle.");
    }

    private static Exception NativeFailure(string operation)
    {
        int error = Marshal.GetLastWin32Error();
        if (error != 0) return new Win32Exception(error, operation + " failed.");
        return new InvalidOperationException(operation + " failed without extended error information.");
    }

    public static Snapshot Read(IntPtr hwnd)
    {
        ValidateWindow(hwnd);
        WindowPlacement placement = new WindowPlacement();
        placement.Length = (uint)Marshal.SizeOf(typeof(WindowPlacement));
        if (!GetWindowPlacement(hwnd, ref placement)) throw NativeFailure("GetWindowPlacement");
        return Decode(placement);
    }

    // Microsoft references: WINDOWPLACEMENT, GetWindowPlacement,
    // ShowWindowAsync and ShowWindow (SW_RESTORE / SW_SHOWMINNOACTIVE).
    // GetWindowPlacement documents flags as zero; decode any returned restore
    // bit as requested, but do not synthesize/write it. Real recovery is left to
    // Windows' SW_RESTORE bookkeeping and must be verified by the caller.
    private static Snapshot Decode(WindowPlacement placement)
    {
        if (placement.Length != (uint)Marshal.SizeOf(typeof(WindowPlacement)))
            throw new InvalidOperationException("Invalid WINDOWPLACEMENT length.");
        Rect rect = placement.NormalPosition;
        if (rect.Right <= rect.Left || rect.Bottom <= rect.Top)
            throw new InvalidOperationException("Invalid WINDOWPLACEMENT normal bounds.");
        bool minimized = placement.ShowCommand == 2 || placement.ShowCommand == 6 ||
            placement.ShowCommand == 7 || placement.ShowCommand == 11;
        bool maximized = minimized ? (placement.Flags & 2) != 0 : placement.ShowCommand == 3;
        return new Snapshot {
            NormalBounds = new int[] { rect.Left, rect.Top, rect.Right, rect.Bottom },
            RestoredState = maximized ? "maximized" : "normal",
            Minimized = minimized, ShowCommand = placement.ShowCommand, Flags = placement.Flags
        };
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    // Desktop WinUser.h: rcDevice exists only under _MAC. Win32 ABI is 44 bytes.
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowPlacement
    {
        public uint Length, Flags, ShowCommand;
        public Point MinPosition, MaxPosition;
        public Rect NormalPosition;
    }
}
