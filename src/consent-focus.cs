using System;
using System.Collections.Generic;

// Matched native consent and service-start intervals can relax foreground checks.
// Completed intervals retain earlier events so unrelated changes cannot disappear.
public sealed class ConsentFocusPolicy {
    sealed class Interval {
        public int Start, End = -1;
        public long Dialog, Parent, After;
        public bool ServiceStart;
    }
    readonly long initialForeground;
    readonly List<Interval> intervals = new List<Interval>();
    public ConsentFocusPolicy(long initialForeground) { this.initialForeground = initialForeground; }
    public bool Active { get { return intervals.Count > 0 && intervals[intervals.Count - 1].End < 0; } }
    public bool ServiceStartActive { get { return Active && intervals[intervals.Count - 1].ServiceStart; } }
    public void BeginServiceStart(int eventIndex, long window) {
        if (Active || eventIndex < 0 || window == 0 ||
            (intervals.Count > 0 && eventIndex < intervals[intervals.Count - 1].End))
            throw new Exception("F_SERVICE_SCOPE_CHANGED");
        intervals.Add(new Interval { Start = eventIndex, Dialog = window, Parent = window, ServiceStart = true });
    }
    public void Begin(int eventIndex, long dialog, long parent) {
        if (Active || eventIndex < 0 || dialog == 0 || parent == 0 || dialog == parent ||
            (intervals.Count > 0 && eventIndex < intervals[intervals.Count - 1].End))
            throw new Exception("F_CONSENT_SCOPE_CHANGED");
        intervals.Add(new Interval { Start = eventIndex, Dialog = dialog, Parent = parent });
    }
    public void Complete(int eventIndex, long foreground) {
        if (!Active) return;
        var interval = intervals[intervals.Count - 1];
        if (eventIndex < interval.Start) throw new Exception("F_CONSENT_SCOPE_CHANGED");
        interval.End = eventIndex;
        interval.After = foreground;
    }
    public bool Allows(long[] events, long foreground) {
        return Allows(events, foreground, true);
    }
    public bool AllowsConsentOnly(long[] events, long foreground) {
        return Allows(events, foreground, false);
    }
    bool Allows(long[] events, long foreground, bool includeServiceStart) {
        int cursor = 0;
        long expected = initialForeground;
        foreach (var interval in intervals) {
            if (interval.ServiceStart && !includeServiceStart) continue;
            if (interval.Start > events.Length) return false;
            for (; cursor < interval.Start; cursor++) if (events[cursor] != expected) return false;
            int end = interval.End < 0 ? events.Length : interval.End;
            if (end > events.Length) return false;
            for (; cursor < end; cursor++)
                if (events[cursor] != expected && events[cursor] != interval.Dialog && events[cursor] != interval.Parent) return false;
            if (interval.End < 0)
                return foreground == expected || foreground == interval.Dialog || foreground == interval.Parent;
            if (interval.After != expected && interval.After != interval.Parent) return false;
            expected = interval.After;
        }
        for (; cursor < events.Length; cursor++) if (events[cursor] != expected) return false;
        return foreground == expected;
    }
}
