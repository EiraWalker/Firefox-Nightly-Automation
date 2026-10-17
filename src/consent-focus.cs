using System;
using System.Collections.Generic;

// Only matched native consent intervals can relax foreground checks. Completed
// intervals remain in the audit so an earlier unrelated change cannot disappear.
public sealed class ConsentFocusPolicy {
    sealed class Interval {
        public int Start, End = -1;
        public long Dialog, Parent, After;
    }
    readonly long initialForeground;
    readonly List<Interval> intervals = new List<Interval>();
    public ConsentFocusPolicy(long initialForeground) { this.initialForeground = initialForeground; }
    public bool Active { get { return intervals.Count > 0 && intervals[intervals.Count - 1].End < 0; } }
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
        int cursor = 0;
        long expected = initialForeground;
        foreach (var interval in intervals) {
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
